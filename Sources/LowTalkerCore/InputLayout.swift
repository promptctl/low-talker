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
    /// The first channel each buffer's frames take in the planar ring, so a render does not
    /// add them up.
    let offsets: [Int]
    let sampleRate: Double

    var channels: Int { buffers.reduce(0, +) }

    init(buffers: [Int], sampleRate: Double) {
        self.buffers = buffers
        self.sampleRate = sampleRate
        var offsets: [Int] = []
        var next = 0
        for channels in buffers {
            offsets.append(next)
            next += channels
        }
        self.offsets = offsets
    }

    /// The shape of what a device offers, from the virtual format of each of its input
    /// streams in stream order: what the HAL presents to a client, as opposed to what the
    /// hardware stores.
    static func parse(_ streams: [AudioStreamBasicDescription]) -> Result<InputLayout, InputRefusal> {
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
        return .success(InputLayout(buffers: buffers, sampleRate: first.mSampleRate))
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
