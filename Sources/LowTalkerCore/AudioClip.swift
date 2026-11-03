import Accelerate
import AVFoundation

/// The pipeline's audio currency: 16 kHz mono Float32 samples.
///
/// [LAW:types-are-the-program] The sample rate is a constant on the type, not a
/// field. A clip at any other rate or channel count is unrepresentable, so the ring
/// buffer, the transcribers, and the latency harness never ask what format they hold.
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    /// The samples `duration` spans at the pipeline rate, to the nearest sample.
    /// [LAW:one-source-of-truth] The one place seconds become sample counts, so a
    /// ring's capacity and a session's pre-roll are measured by the same rule.
    public static func sampleCount(for duration: TimeInterval) -> Int {
        Int((duration * sampleRate).rounded())
    }

    /// The seconds `count` samples span at the pipeline rate, the inverse of
    /// `sampleCount(for:)` up to that rounding.
    public static func duration(for count: Int) -> TimeInterval {
        Double(count) / sampleRate
    }

    public let samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval {
        Self.duration(for: samples.count)
    }

    /// Largest absolute sample value; zero for silence.
    public var peak: Float { Self.peak(of: samples[...]) }

    /// The largest magnitude among `samples`, 0 for none. [LAW:one-source-of-truth] The one
    /// peak reader, for a clip and for a window of one alike.
    ///
    /// Read by vDSP: a generic reduce over a long clip held a thread for seconds in a debug
    /// build, which starved the CI runner's cooperative pool (low-unfiled-50ff.cis). vDSP can
    /// answer NaN for a clip holding one, where a sample that is not a number has no
    /// magnitude, so that rare clip is read again without it.
    public static func peak(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let peak = vDSP.maximumMagnitude(samples)
        return peak.isNaN ? samples.reduce(0) { $1.isNaN ? $0 : max($0, abs($1)) } : peak
    }

    /// The clip cut into consecutive clips `duration` long, the last holding
    /// whatever remains; an empty clip is no chunks at all.
    public func chunks(of duration: TimeInterval) -> [AudioClip] {
        let length = Self.sampleCount(for: duration)
        precondition(length > 0, "a chunk holds at least one sample")
        return stride(from: 0, to: samples.count, by: length).map { start in
            AudioClip(samples: Array(samples[start..<min(start + length, samples.count)]))
        }
    }
}

public enum AudioClipError: Error, CustomStringConvertible {
    /// AVFoundation could not open the file; the CoreAudio error is attached.
    case unreadable(URL, underlying: any Error)
    /// AVFoundation could not create or fill the file; the CoreAudio error is attached.
    case unwritable(URL, underlying: any Error)
    /// More frames than a single AVFoundation buffer can hold.
    case tooLong(frames: Int64)
    /// The header's length and rate give no count of pipeline samples: a rate of 0 Hz, which
    /// AVAudioConverter takes, or a length past what a clip can count.
    case unmeasurable(frames: Int64, sampleRate: Double)
    /// The file ran out of audio before the length its header declares.
    case truncated(URL, read: Int64, declared: Int64)
    /// The file holds more audio than the reader was told to take.
    case longerThan(TimeInterval, seconds: TimeInterval)
    /// AVFoundation has no conversion path from the source format to 16 kHz mono.
    case unconvertibleFormat(sampleRate: Double, channels: UInt32)
    /// The converter accepted the format pair but failed mid-stream; AVFoundation may
    /// or may not attach a reason.
    case conversionFailed(underlying: (any Error)?)
    case bufferAllocationFailed

    public var description: String {
        switch self {
        case .unreadable(let url, let underlying):
            "cannot read audio file \(url.path): \(underlying)"
        case .unwritable(let url, let underlying):
            "cannot write audio file \(url.path): \(underlying)"
        case .tooLong(let frames):
            "\(frames) frames; a single audio buffer holds at most \(AVAudioFrameCount.max)"
        case .unmeasurable(let frames, let sampleRate):
            "\(frames) frames at \(sampleRate) Hz is no length in samples"
        case .truncated(let url, let read, let declared):
            "audio file \(url.path) ends after \(read) of the \(declared) frames it declares"
        case .longerThan(let limit, let seconds):
            "\(seconds.formatted(.number.precision(.fractionLength(1)))) seconds of audio; at most \(limit.formatted(.number.precision(.fractionLength(1)))) are taken"
        case .unconvertibleFormat(let sampleRate, let channels):
            "no conversion from \(sampleRate) Hz, \(channels) channel(s) to \(AudioClip.sampleRate) Hz mono"
        case .conversionFailed(let underlying):
            "audio conversion failed: \(underlying.map { "\($0)" } ?? "no detail from AVFoundation")"
        case .bufferAllocationFailed:
            "could not allocate an audio buffer"
        }
    }
}

extension AudioClip {
    /// Deinterleaved Float32 at the pipeline rate. `standardFormat` never fails for a
    /// positive rate and channel count, so the unwrap is a static fact, not a guess.
    /// Computed rather than stored: the macOS 15 SDK does not mark AVAudioFormat
    /// Sendable, so Swift 6 rejects it as a static let there.
    static var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)! }

    /// Load any file AVFoundation can read (wav, aiff, m4a, ...) as a clip, refusing one
    /// that holds more than `longest` seconds before any of its audio is read.
    ///
    /// [LAW:parse-dont-validate] This is the one boundary where file audio of any
    /// rate and channel count becomes a clip. Resampling and downmixing happen here,
    /// once; nothing downstream sees anything but 16 kHz mono.
    public init(contentsOf url: URL, longest: TimeInterval = .infinity) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioClipError.unreadable(url, underlying: error)
        }
        let source = file.processingFormat
        // The length is read off the file's header, so a compressed file that would decode
        // to hours is refused before any of it is. The rate is the header's say-so too, so the
        // two become a count here or not at all, and every figure after is that count's.
        guard let count = Int(exactly: (Double(file.length) * Self.sampleRate / source.sampleRate).rounded()) else {
            throw AudioClipError.unmeasurable(frames: file.length, sampleRate: source.sampleRate)
        }
        let seconds = Self.duration(for: count)
        guard seconds <= longest else { throw AudioClipError.longerThan(longest, seconds: seconds) }
        let converter = try Converter(from: source)
        // A converter's piece at a time, so the file's audio is in memory once, as the clip, and
        // never also whole in the source format. Sized in frames, not seconds: the header's rate
        // and channel count are the file's say-so, and a second of 768 kHz across 256 channels
        // is 786 MB.
        guard let chunk = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: Converter.pieceFrames) else {
            throw AudioClipError.bufferAllocationFailed
        }
        var samples: [Float] = []
        // A piece past the length, for the resampler's tail, so the drain never grows the clip
        // by copying it.
        samples.reserveCapacity(count + Int(Converter.pieceFrames))
        while file.framePosition < file.length {
            do {
                try file.read(into: chunk)
            } catch {
                throw AudioClipError.unreadable(url, underlying: error)
            }
            // [LAW:no-silent-failure] A read that ends short of the header's length is a file
            // that lies about itself, not the end of the loop.
            guard chunk.frameLength > 0 else { throw AudioClipError.truncated(url, read: file.framePosition, declared: file.length) }
            samples += try converter.convert(chunk)
        }
        samples += try converter.drain()
        self.init(samples: samples)
    }

    /// Write as a 16-bit PCM wav at the pipeline rate, the encoding every player and
    /// engine loader accepts. The inverse of `init(contentsOf:)` up to 16-bit rounding.
    public func write(to url: URL) throws {
        guard let frameCount = AVAudioFrameCount(exactly: samples.count) else {
            throw AudioClipError.tooLong(frames: Int64(samples.count))
        }
        // A zero-capacity buffer allocates no channel memory and its channel pointer
        // is NULL; one spare frame keeps the pointer valid when the clip is empty.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: max(frameCount, 1)) else {
            throw AudioClipError.bufferAllocationFailed
        }
        // Standard float format guarantees channel data; channel 0 is the only channel.
        _ = UnsafeMutableBufferPointer(start: buffer.floatChannelData![0], count: samples.count).update(fromContentsOf: samples)
        buffer.frameLength = frameCount

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            file.close()
        } catch {
            throw AudioClipError.unwritable(url, underlying: error)
        }
    }
}
