import AVFoundation
import CoreAudio
import GrammaticalNumber

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
    /// Every channel of every buffer.
    let channels: Int
    let sampleRate: Double
    /// Which of the device's channels are heard, and why those.
    let heardChannels: HeardChannels
    /// Where each heard channel is in a render, in the order the ring holds them.
    let heard: [Lane]

    /// A channel's place in a render: its buffer, and its lane among that buffer's interleaved
    /// channels.
    struct Lane: Sendable, Equatable {
        let buffer: Int
        let lane: Int
    }

    init(buffers: [Int], sampleRate: Double, stereo: StereoChannels) {
        self.buffers = buffers
        self.sampleRate = sampleRate
        channels = buffers.reduce(0, +)
        heardChannels = HeardChannels(of: channels, stereo: stereo)
        let lanes = buffers.enumerated().flatMap { buffer, width in (0..<width).map { Lane(buffer: buffer, lane: $0) } }
        heard = heardChannels.channels.map { lanes[$0 - 1] }
    }

    /// What the heard channels are popped in and converted from: float samples at the device's
    /// rate, one buffer per heard channel. At most two, which is what lets AVAudioFormat
    /// describe it whatever the device's channel count; past two it describes none without a
    /// channel layout, and given one AVAudioConverter mixes it to silence
    /// (low-reliability-z2z.n4b).
    var format: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(heard.count), interleaved: false)
    }

    /// The shape of what a device offers, from the virtual format of each of its input
    /// streams in stream order, what the HAL presents to a client as opposed to what the
    /// hardware stores, and the channels it names for stereo.
    static func parse(_ streams: [AudioStreamBasicDescription], stereo: StereoChannels) -> Result<InputLayout, InputRefusal> {
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
        return .success(InputLayout(buffers: buffers, sampleRate: first.mSampleRate, stereo: stereo))
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
        let held = "buffer \(buffer) of \(gotBuffers) held \(counted(gotBytes, "byte", "bytes"))"
        switch reason {
        case .bufferCount: return "\(counted(gotBuffers, "buffer", "buffers")) where \(counted(expectedBuffers, "was expected", "were expected"))"
        case .channels: return "\(held) over \(counted(gotChannels, "channel", "channels")) where \(counted(expectedChannels, "was expected", "were expected"))"
        case .partialFrame: return "\(held), which is not a whole number of frames of \(counted(expectedChannels, "channel", "channels"))"
        case .noMemory: return "\(held) with no memory behind them"
        case .unequalFrames(let before):
            return "\(held), \(counted(gotBytes / (MemoryLayout<Float>.size * max(expectedChannels, 1)), "frame", "frames")) where the buffers before it held \(before)"
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

    public var description: String {
        switch self {
        case .noStream: "it has no input stream"
        case .notLinearPCM(let id): "its input is not linear PCM (format \(id))"
        case .notFloat32(let bits): "its input is not 32-bit float (\(bits) bits)"
        case .notPacked: "its input samples are not packed"
        case .bigEndian: "its input samples are big-endian"
        case .mixedSampleRates(let a, let b): "its input streams run at different sample rates (\(a) and \(b) Hz)"
        case .noChannels: "its input carries no channels"
        }
    }
}

/// The channels a device names for stereo input (`kAudioDevicePropertyPreferredChannelsForStereo`),
/// numbered from 1 as CoreAudio numbers them, or what CoreAudio answered when asked for them.
public enum StereoChannels: Sendable, Equatable {
    case named(Int, Int)
    case unpublished(OSStatus)
}

/// Which channels of a device are heard, numbered from 1. A device of one or two is heard on
/// all of them, exactly as before wider devices could be: AVAudioConverter mixes two as it mixes
/// any stereo input, half of each (measured). A wider device is heard on the two it names for
/// stereo, or the one it names twice, since AVAudioFormat describes no more than two without a
/// channel layout. One that names none it has is heard on its first two rather than refused,
/// because a refused device fails every press.
public struct HeardChannels: Sendable, Equatable, CustomStringConvertible {
    /// Why these channels. Private, so `init` is the one way to make one and no case is held with
    /// a count or a pair it did not check.
    private let source: Source

    private enum Source: Sendable, Equatable {
        /// Every channel of a device of one or two.
        case every(Int)
        /// The channels a wider device names for stereo.
        case named(Int, Int)
        /// The first two channels of a wider device that names none it has, and what it named.
        case first(StereoChannels)
    }

    /// For a device of `count` channels, at least one.
    public init(of count: Int, stereo: StereoChannels) {
        source = switch stereo {
        case _ where count <= 2: .every(count)
        case .named(let left, let right) where (1...count).contains(left) && (1...count).contains(right): .named(left, right)
        default: .first(stereo)
        }
    }

    public var channels: [Int] {
        switch source {
        case .every(let count): Array(1...count)
        case .named(let left, let right): left == right ? [left] : [left, right]
        case .first: [1, 2]
        }
    }

    /// Whether naming other channels for stereo would change which are heard, which is when the
    /// pair is watched.
    var followsStereo: Bool {
        switch source {
        case .every, .first(.unpublished): false
        case .named, .first(.named): true
        }
    }

    public var description: String {
        let heard = channels.count == 1 ? "heard on channel \(channels[0])" : "heard on channels \(channels[0]) and \(channels[1])"
        return switch source {
        case .every, .named: heard
        case .first(.named(let left, let right)): "\(heard), its first: it names channels \(left) and \(right) for stereo"
        case .first(.unpublished(let status)): "\(heard), its first: it names no channels for stereo (status \(status))"
        }
    }
}
