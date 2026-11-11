import AVFoundation

extension AudioClip {
    /// Converts a stream of buffers in one source format into pipeline samples.
    ///
    /// One stream at a time: the resampler carries its state between calls so a
    /// chunk boundary is inaudible, `drain` releases the tail of a stream read to its
    /// end, and `reset` begins another. The microphone, the file loader and each
    /// realtime session hold one apiece.
    ///
    /// Calls are serialized by the caller. Not Sendable: it holds AVFoundation objects
    /// the macOS 15 SDK does not mark Sendable, so the microphone holds it as
    /// `nonisolated(unsafe)`, converting on a press's delivery thread while the press runs
    /// and resetting on the main actor only once that thread has ended.
    public final class Converter {
        /// The most the converter has been seen to ask for at once; a smaller piece
        /// would only mean more asks.
        public static let pieceFrames: AVAudioFrameCount = 4_096
        /// What it converts from.
        public var source: AVAudioFormat { converter.inputFormat }
        private let converter: AVAudioConverter
        /// What the converter is handed per ask, in the source format.
        private let piece: AVAudioPCMBuffer
        /// What the converter fills per call, in the pipeline format.
        private let scratch: AVAudioPCMBuffer

        public init(from source: AVAudioFormat) throws {
            guard let converter = AVAudioConverter(from: source, to: AudioClip.format) else {
                throw AudioClipError.unconvertibleFormat(sampleRate: source.sampleRate, channels: source.channelCount)
            }
            // Without this, extra source channels are discarded rather than mixed; the
            // right-only fixture loads as silence.
            converter.downmix = true
            guard let piece = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: Self.pieceFrames),
                  let scratch = AVAudioPCMBuffer(pcmFormat: AudioClip.format, frameCapacity: 16_384)
            else {
                throw AudioClipError.bufferAllocationFailed
            }
            self.converter = converter
            self.piece = piece
            self.scratch = scratch
        }

        /// The pipeline samples for the whole of `input`.
        public func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
            try pull(input, then: .noDataNow)
        }

        /// The resampler's tail. The stream is over; convert nothing more after this.
        public func drain() throws -> [Float] {
            try pull(nil, then: .endOfStream)
        }

        /// Begins a new stream on this instance. The resampler's state belongs to the
        /// stream that filled it, so a caller that reuses one converter across streams
        /// that are not continuous - the microphone, whose device is closed between
        /// presses - says so here rather than bleeding one press's tail into the head of
        /// the next.
        ///
        /// That press's own tail is not drained, and cannot be: `endSession` cuts the
        /// clip and `dispose` stops the ring accepting before either reaches `close()`,
        /// so by the time the device is stopped the six-odd samples the resampler still
        /// holds have nowhere left to be delivered. The head of the next press is where
        /// that residue can still be stopped, and stopping it is what this does.
        public func reset() { converter.reset() }

        private func pull(_ input: AVAudioPCMBuffer?, then exhausted: AVAudioConverterInputStatus) throws -> [Float] {
            // The converter asks for a packet count per ask and holds any surplus it is
            // handed until the next call; handed a whole 100 ms buffer, it returns
            // up to 90 ms of it late. Serving each ask no more than it asked for, from a
            // cursor over the input, leaves nothing held: every call returns all of its
            // input, and only the resampler's few-sample tail waits for `drain`.
            // [LAW:no-shared-mutable-globals] exception: the SDK types the block
            // @Sendable, but `convert` calls it synchronously on this thread, so nothing
            // is shared. A Mutex would satisfy the annotation only where AVAudioFormat
            // is Sendable (macOS 26 SDK); on the macOS 15 SDK the buffers share a region
            // with the converter and cannot be sent into one.
            nonisolated(unsafe) let input = input
            nonisolated(unsafe) let piece = piece
            nonisolated(unsafe) var cursor = 0
            var samples: [Float] = []
            while true {
                var conversionError: NSError?
                let status = converter.convert(to: scratch, error: &conversionError) { asked, inputStatus in
                    guard let input, cursor < Int(input.frameLength) else {
                        inputStatus.pointee = exhausted
                        return nil
                    }
                    let frames = min(Int(input.frameLength) - cursor, Int(asked), Int(piece.frameCapacity))
                    piece.fill(from: input, offset: cursor, frames: frames)
                    cursor += frames
                    inputStatus.pointee = .haveData
                    return piece
                }
                switch status {
                case .haveData, .inputRanDry, .endOfStream:
                    // Standard float format guarantees channel data; channel 0 is the only channel.
                    samples.append(contentsOf: UnsafeBufferPointer(start: scratch.floatChannelData![0], count: Int(scratch.frameLength)))
                    // `.haveData` means the scratch buffer filled before the input ran out.
                    if status != .haveData { return samples }
                case .error:
                    throw AudioClipError.conversionFailed(underlying: conversionError)
                @unknown default:
                    throw AudioClipError.conversionFailed(underlying: conversionError)
                }
            }
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Becomes `frames` frames of `source` starting at `offset`, whatever the sample
    /// layout: each channel buffer is copied at its own byte stride.
    func fill(from source: AVAudioPCMBuffer, offset: Int, frames: Int) {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        for (from, to) in zip(sources, UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)) {
            to.mData!.copyMemory(from: from.mData! + offset * bytesPerFrame, byteCount: frames * bytesPerFrame)
        }
        frameLength = AVAudioFrameCount(frames)
    }
}
