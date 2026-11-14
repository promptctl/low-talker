import AVFoundation
import CoreAudio
import Synchronization
import Uptime

/// One press's audio on its way from CoreAudio's IO thread to the pipeline.
///
/// The IO thread hands each buffer list here, which holds it to the shape the microphone was
/// readied under, pushes what passes into a `SliceRing` and signals; a thread of the press's
/// own pops it, converts it to pipeline samples and hands it over. Everything that can wait
/// or allocate happens on that thread rather than the IO thread: the converter's arrays, the
/// boxed errors, and above all the lock on the capture's stream, which the main actor holds
/// while it copies a whole session out of the ring at key-up. Waiting for it here costs no
/// deadline; the ring holds what arrives meanwhile.
///
/// A semaphore is the one way in from the IO thread because signalling one never waits: it
/// wakes a waiter or counts, and takes no lock a waiter could be holding.
///
/// [LAW:types-are-the-program] exception: `@unchecked Sendable` because the converter and the
/// buffer it reads hold AVFoundation objects the macOS 15 SDK does not mark Sendable. Only the
/// delivery thread touches them between `init` and the return of `finish()`.
final class SliceDelivery: @unchecked Sendable {
    private let ring: SliceRing
    private let doorbell = DispatchSemaphore(value: 0)
    private let ended = DispatchSemaphore(value: 0)
    private let finishing = Atomic<Bool>(false)
    nonisolated(unsafe) private let converter: AudioClip.Converter
    /// What each slice is popped into for the converter to read.
    nonisolated(unsafe) private let popped: AVAudioPCMBuffer
    private let appending: @Sendable ([Float], HostTime) -> Void
    private let onFailure: @Sendable (any Error) -> Void
    private let layout: InputLayout
    /// The most frames one slice can carry, which is what the delivery's buffers were sized
    /// for.
    private let capacity: Int
    /// The IO thread's alone, like `framesPushed` in the ring: whether a buffer list of the
    /// layout has been pushed this press, and whether a fault has. Either fault ends the press
    /// (a shape change replaces the input, an overlong slice fails it), so it is reported
    /// once, however many renders follow it - and tried again while the ring is too full to
    /// take it, because a fault that was dropped reports nothing.
    nonisolated(unsafe) private var matched = false
    nonisolated(unsafe) private var faulted = false
    /// How many of the ring's drops have been reported. The delivery thread's alone.
    nonisolated(unsafe) private var reportedDrops = 0

    /// Starts the thread. `slice` is the most frames one slice can carry; `converter` is the
    /// delivery's until `finish()` returns.
    init(
        _ ring: SliceRing,
        layout: InputLayout,
        slice: Int,
        format: AVAudioFormat,
        converter: AudioClip.Converter,
        appending: @escaping @Sendable ([Float], HostTime) -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) throws {
        guard let popped = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice)) else {
            throw AudioClipError.bufferAllocationFailed
        }
        self.ring = ring
        self.layout = layout
        self.capacity = slice
        self.popped = popped
        self.converter = converter
        self.appending = appending
        self.onFailure = onFailure
        let thread = Thread { [self] in run() }
        thread.name = "ai.promptctl.low-talker.delivery"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// IO thread: one render's buffer list, captured at `stamp`.
    ///
    /// A shape fault is `shapeNeverMatched` until a list of the layout has been heard and
    /// `inputShapeChanged` after, because they have different answers: a device that changed
    /// under a press is replaced, and one that never matched would be replaced into the same
    /// mismatch. [LAW:no-silent-failure] A device is free to deliver a cycle with no frames,
    /// which is not a shape fault.
    func deliver(_ list: UnsafePointer<AudioBufferList>, stamp: AudioTimeStamp) {
        guard !faulted else { return }
        switch layout.verdict(of: list, capacity: capacity) {
        case .empty:
            return
        case .overlong(let frames):
            faulted = ring.push(.overlongSlice(frames: frames, capacity: capacity))
        case .shape(let mismatch):
            faulted = ring.push(matched ? .inputShapeChanged(mismatch) : .shapeNeverMatched(mismatch))
        case .frames(let frames):
            matched = true
            ring.push(list, layout: layout, frames: frames, stamp: stamp)
        }
        doorbell.signal()
    }

    /// Hands over what is left and returns once the thread has ended, after which the
    /// converter is the caller's again. Called once the IO thread has stopped delivering:
    /// what it pushed before that is delivered, and nothing after it exists.
    func finish() {
        finishing.store(true, ordering: .releasing)
        doorbell.signal()
        ended.wait()
    }

    private func run() {
        while true {
            doorbell.wait()
            // Read before the drain, so a drain that follows `finish()` is one that sees
            // everything the IO thread pushed before it stopped.
            let last = finishing.load(ordering: .acquiring)
            drain()
            if last { break }
        }
        ended.signal()
    }

    private func drain() {
        while let entry = ring.pop(into: popped) {
            switch entry {
            case .slice(_, let stamp):
                do {
                    // Parsed before the slice is converted: converting first would feed it into
                    // the resampler and then throw the output away when the stamp turns out to
                    // be unplaceable, leaving the filter primed by audio nobody has.
                    // [LAW:parse-dont-validate]
                    let captured = try HostTime(stamp)
                    appending(try converter.convert(popped), captured)
                } catch {
                    onFailure(error)
                }
            case .fault(let fault):
                onFailure(fault)
            }
        }
        let dropped = ring.dropped
        if dropped > reportedDrops {
            reportedDrops = dropped
            onFailure(AudioHardwareError.deliveryFellBehind(dropped: dropped))
        }
    }
}
