import Accelerate
import CoreAudio

/// What a device's IOProc hands over, as a shape: how many buffers there are, how many
/// channels each carries, and the one sample rate they share.
///
/// The IOProc is given the device's own buffers, one per input stream for an interleaved
/// stream and one per channel for a non-interleaved one, where the HAL audio unit this
/// replaced merged them and converted whatever it found. So the shape is read once, when
/// the microphone is readied, and every buffer list a render brings is held to it: audio
/// copied under a shape it was not read under is noise that sounds like speech.
/// [LAW:parse-dont-validate] A `Reach` exists only for a device whose shape parsed.
///
/// Both halves are pure, so the table of shapes a device can offer and the table of buffer
/// lists a render can bring are tested without a device.
struct InputLayout: Sendable, Equatable {
    /// The channels of each buffer, in the order the IOProc is handed them.
    let buffers: [Int]
    let sampleRate: Double
    /// The device's channels for stereo, which are what it is heard as.
    let stereo: StereoPair
    /// Where each of them is in a render: its buffer, and its lane among that buffer's
    /// interleaved channels.
    private let left: Lane
    private let right: Lane

    private struct Lane: Sendable, Equatable {
        let buffer: Int
        let lane: Int
    }

    var channels: Int { buffers.reduce(0, +) }

    /// Refused when the device names a channel for stereo that it does not have.
    init(buffers: [Int], sampleRate: Double, stereo: StereoPair) throws(InputRefusal) {
        func locate(_ channel: Int) throws(InputRefusal) -> Lane {
            var first = 1
            for (buffer, width) in buffers.enumerated() {
                if (first..<first + width).contains(channel) { return Lane(buffer: buffer, lane: channel - first) }
                first += width
            }
            throw .noStereoChannel(channel, channels: first - 1)
        }
        self.buffers = buffers
        self.sampleRate = sampleRate
        self.stereo = stereo
        left = try locate(stereo.left)
        right = try locate(stereo.right)
    }

    /// The shape of what a device offers, from the virtual format of each of its input
    /// streams in stream order, what the HAL presents to a client as opposed to what the
    /// hardware stores, and the channels it names for stereo.
    static func parse(_ streams: [AudioStreamBasicDescription], stereo: StereoPair) -> Result<InputLayout, InputRefusal> {
        guard let first = streams.first else { return .failure(.noStream) }
        var buffers: [Int] = []
        for stream in streams {
            guard stream.mFormatID == kAudioFormatLinearPCM else { return .failure(.notLinearPCM(formatID: stream.mFormatID)) }
            guard stream.mFormatFlags & kAudioFormatFlagIsFloat != 0, stream.mBitsPerChannel == 32 else {
                return .failure(.notFloat32(bits: stream.mBitsPerChannel))
            }
            guard stream.mFormatFlags & kAudioFormatFlagIsPacked != 0 else { return .failure(.notPacked) }
            guard stream.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return .failure(.bigEndian) }
            guard stream.mSampleRate == first.mSampleRate else { return .failure(.mixedSampleRates(first.mSampleRate, stream.mSampleRate)) }
            let channels = Int(stream.mChannelsPerFrame)
            if stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                buffers.append(contentsOf: repeatElement(1, count: channels))
            } else if channels > 0 {
                buffers.append(channels)
            }
        }
        guard !buffers.isEmpty else { return .failure(.noChannels) }
        return Result { () throws(InputRefusal) in try InputLayout(buffers: buffers, sampleRate: first.mSampleRate, stereo: stereo) }
    }

    /// The one channel `frames` frames of a render are heard as, from frame `start`: the mean of
    /// the device's channels for stereo. A mono device names its one channel twice and passes as
    /// it is; a stereo device is mixed as AVAudioConverter mixed it before (half of each,
    /// measured); a wider one, an audio interface or a loopback, is heard on the two channels
    /// macOS treats as its stereo, and its other channels, and their hiss, are not mixed in.
    ///
    /// Mixed here because AVAudioConverter cannot be handed a device wider than two channels:
    /// AVAudioFormat describes no such format without a channel layout, and given one the
    /// converter mixes it to silence (low-reliability-z2z.n4b). Reads only what `verdict` has
    /// held the list to, so it allocates nothing and runs on the IO thread.
    func mix(_ list: UnsafePointer<AudioBufferList>, from start: Int, frames: Int, into destination: UnsafeMutablePointer<Float>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        func samples(_ channel: Lane) -> UnsafePointer<Float> {
            UnsafePointer(list[channel.buffer].mData!.assumingMemoryBound(to: Float.self) + start * buffers[channel.buffer] + channel.lane)
        }
        var half: Float = 0.5
        vDSP_vasm(
            samples(left), vDSP_Stride(buffers[left.buffer]),
            samples(right), vDSP_Stride(buffers[right.buffer]),
            &half, destination, 1, vDSP_Length(frames)
        )
    }

    /// What one render's buffer list comes to against this shape.
    enum Verdict: Equatable {
        /// This many frames per channel, all of the shape.
        case frames(Int)
        /// A cycle that carried no frames, which a device is free to deliver.
        case empty
        /// More frames than the press sized its buffers for.
        case overlong(frames: Int)
        case shape(ShapeMismatch)
    }

    /// Reads a buffer list from the IO thread, so it allocates nothing: every answer is a
    /// handful of integers. A buffer's frame count is its byte size over four bytes a
    /// channel; a size that is not a whole number of frames, or a size with no memory behind
    /// it, is not a buffer of this shape.
    func verdict(of list: UnsafePointer<AudioBufferList>, capacity: Int) -> Verdict {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        func mismatch(_ reason: ShapeMismatch.Reason, at index: Int = 0) -> Verdict {
            let buffer = index < list.count ? list[index] : AudioBuffer()
            return .shape(ShapeMismatch(
                reason: reason, expectedBuffers: buffers.count, gotBuffers: list.count, buffer: index,
                expectedChannels: index < buffers.count ? buffers[index] : 0,
                gotChannels: Int(buffer.mNumberChannels), gotBytes: Int(buffer.mDataByteSize)
            ))
        }
        guard list.count == buffers.count else { return mismatch(.bufferCount) }
        var frames: Int?
        for index in 0..<buffers.count {
            let buffer = list[index]
            let expected = buffers[index]
            let bytes = Int(buffer.mDataByteSize)
            guard Int(buffer.mNumberChannels) == expected else { return mismatch(.channels, at: index) }
            guard bytes % (MemoryLayout<Float>.size * expected) == 0 else { return mismatch(.partialFrame, at: index) }
            guard bytes == 0 || buffer.mData != nil else { return mismatch(.noMemory, at: index) }
            let these = bytes / (MemoryLayout<Float>.size * expected)
            guard these == (frames ?? these) else { return mismatch(.unequalFrames(before: frames ?? these), at: index) }
            frames = these
        }
        guard let frames, frames > 0 else { return .empty }
        return frames > capacity ? .overlong(frames: frames) : .frames(frames)
    }
}

/// The first buffer of a render that was not of the shape the microphone was readied under,
/// in integers only, because it is made on the IO thread. [LAW:nothing-unseen]
public struct ShapeMismatch: Equatable, Sendable, CustomStringConvertible {
    /// Which check the buffer failed, because the integers alone do not say: two buffers of
    /// one channel each can differ only in how many frames they hold.
    enum Reason: Equatable, Sendable {
        case bufferCount
        case channels
        /// A byte size that is not a whole number of frames of the buffer's channels.
        case partialFrame
        /// A byte size with no memory behind it.
        case noMemory
        /// A different number of frames from the buffers before it.
        case unequalFrames(before: Int)
    }

    let reason: Reason
    let expectedBuffers: Int
    let gotBuffers: Int
    let buffer: Int
    let expectedChannels: Int
    let gotChannels: Int
    let gotBytes: Int

    public var description: String {
        let held = "buffer \(buffer) of \(gotBuffers) held \(gotBytes) bytes"
        switch reason {
        case .bufferCount: return "\(gotBuffers) buffers where \(expectedBuffers) were expected"
        case .channels: return "\(held) over \(gotChannels) channels where \(expectedChannels) were expected"
        case .partialFrame: return "\(held), which is not a whole number of frames of \(expectedChannels) channels"
        case .noMemory: return "\(held) with no memory behind them"
        case .unequalFrames(let before):
            return "\(held), \(gotBytes / (MemoryLayout<Float>.size * max(expectedChannels, 1))) frames where the buffers before it held \(before)"
        }
    }
}

/// Why a device's input cannot be read. Each names what the device offered, so the press
/// that is refused says which device and which shape rather than "unavailable".
/// [LAW:no-silent-failure]
public enum InputRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case noStream
    case notLinearPCM(formatID: UInt32)
    case notFloat32(bits: UInt32)
    case notPacked
    case bigEndian
    case mixedSampleRates(Double, Double)
    case noChannels
    /// The device names a channel for stereo past the channels it has.
    case noStereoChannel(Int, channels: Int)

    public var description: String {
        switch self {
        case .noStream: "it has no input stream"
        case .notLinearPCM(let id): "its input is not linear PCM (format \(id))"
        case .notFloat32(let bits): "its input is not 32-bit float (\(bits) bits)"
        case .notPacked: "its input samples are not packed"
        case .bigEndian: "its input samples are big-endian"
        case .mixedSampleRates(let a, let b): "its input streams run at different sample rates (\(a) and \(b) Hz)"
        case .noChannels: "its input carries no channels"
        case .noStereoChannel(let channel, let channels): "it names channel \(channel) for stereo and has \(channels) input channel\(channels == 1 ? "" : "s")"
        }
    }
}

/// The two channels a device names for stereo input (`kAudioDevicePropertyPreferredChannelsForStereo`),
/// numbered from 1 as CoreAudio numbers them. A mono device names its one channel twice.
public struct StereoPair: Sendable, Equatable, CustomStringConvertible {
    public let left: Int
    public let right: Int

    public init(left: Int, right: Int) {
        self.left = left
        self.right = right
    }

    public var description: String { left == right ? "channel \(left)" : "channels \(left) and \(right)" }
}
