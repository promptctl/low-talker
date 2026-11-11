import AVFoundation
import CoreAudio
import Synchronization

/// The slices the IOProc's block hands over, in a single-producer single-consumer ring buffer:
/// CoreAudio's IO thread pushes, and one thread with no deadline pops.
///
/// Lock-free and allocation-free at the push, because the IO thread renders under a hard
/// deadline and anything that can wait or reach the allocator there can make it miss one.
/// Every byte the ring uses is allocated and written once when it is made, so a push touches
/// no page for the first time either. [LAW:no-ambient-temporal-coupling] Each end owns the
/// counters it writes and publishes them with release ordering; the other end reads them with
/// acquire, which is the whole of what orders a slice's samples before its entry.
///
/// A full ring drops the slice rather than wait for room, and counts it: a producer that
/// blocked would be the very wait this type exists to remove, and a count is how the consumer
/// learns the press lost audio. [LAW:no-silent-failure]
///
/// [LAW:types-are-the-program] exception: `@unchecked Sendable` because both ends are reached
/// from two threads through raw storage. What makes that sound is the ownership above: every
/// counter and every slot has one writer at a time, and the slots a push writes are ones the
/// consumer has published as read.
final class SliceRing: @unchecked Sendable {
    /// One thing the IO thread handed over, in the order it happened.
    enum Entry {
        /// The next `frames` frames, the first captured at `stamp`.
        case slice(frames: Int, stamp: AudioTimeStamp)
        /// A render that delivered nothing, and why. Typed rather than `any Error`, because
        /// boxing an existential allocates and this is made on the IO thread.
        case fault(AudioHardwareError)
    }

    /// Frames the ring holds.
    let capacity: Int
    /// The shape of the renders it is pushed, each held as the one channel it is heard as.
    let layout: InputLayout
    private let samples: UnsafeMutablePointer<Float>
    private let entries: UnsafeMutablePointer<Entry>
    private let entryCapacity: Int

    /// Entries ever pushed and ever popped, each written only by its own end.
    private let pushed = Atomic<Int>(0)
    private let popped = Atomic<Int>(0)
    /// Frames ever popped: what a push measures the room left against.
    private let framesPopped = Atomic<Int>(0)
    /// Frames ever pushed. The producer's alone; the consumer finds a slice's frames by
    /// counting its own.
    nonisolated(unsafe) private var framesPushed = 0
    private let droppedCount = Atomic<Int>(0)

    /// A ring for renders of `layout`.
    init(_ layout: InputLayout, frames capacity: Int, entries entryCapacity: Int) {
        precondition(layout.channels > 0 && capacity > 0 && entryCapacity > 0, "a ring holds something")
        self.layout = layout
        self.capacity = capacity
        self.entryCapacity = entryCapacity
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        entries = .allocate(capacity: entryCapacity)
        entries.initialize(repeating: .slice(frames: 0, stamp: AudioTimeStamp()), count: entryCapacity)
    }

    deinit {
        entries.deinitialize(count: entryCapacity)
        entries.deallocate()
        samples.deallocate()
    }

    /// Slices and faults that found the ring full and were never handed over.
    var dropped: Int { droppedCount.load(ordering: .relaxed) }

    /// Producer end: mixes `frames` frames of `list` in, a render of the ring's layout. The
    /// caller has already held `list` to that layout (`InputLayout.verdict`), which is what
    /// makes every read here in bounds.
    func push(_ list: UnsafePointer<AudioBufferList>, frames: Int, stamp: AudioTimeStamp) {
        let start = framesPushed
        guard start + frames - framesPopped.load(ordering: .acquiring) <= capacity else {
            return drop()
        }
        guard let slot = claim() else { return drop() }
        let at = start % capacity
        layout.mix(list, frames: frames, into: samples + at, min(frames, capacity - at), then: samples)
        framesPushed = start + frames
        publish(.slice(frames: frames, stamp: stamp), at: slot)
    }

    /// Producer end: a render that had nothing to hand over. Answers whether the fault was
    /// handed over, so a caller that reports a fault once can keep trying while the ring is
    /// full rather than count a fault nobody will read as reported.
    @discardableResult
    func push(_ fault: AudioHardwareError) -> Bool {
        guard let slot = claim() else {
            drop()
            return false
        }
        publish(.fault(fault), at: slot)
        return true
    }

    /// The shape a slice is popped in: one channel of float samples at the device's rate, which
    /// AVAudioFormat describes whatever the device's channel count.
    static func format(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Consumer end: the oldest entry, or nil when there is none. A slice's frames are copied
    /// into `buffer`, one channel like the ring, whose frame length becomes the slice's.
    func pop(into buffer: AVAudioPCMBuffer) -> Entry? {
        let next = popped.load(ordering: .relaxed)
        guard next < pushed.load(ordering: .acquiring) else { return nil }
        let entry = entries[next % entryCapacity]
        if case .slice(let frames, _) = entry {
            precondition(frames <= Int(buffer.frameCapacity), "a slice larger than the buffer it is popped into")
            precondition(buffer.format.channelCount == 1, "a slice is one channel")
            let start = framesPopped.load(ordering: .relaxed)
            let at = start % capacity
            let head = min(frames, capacity - at)
            let destination = buffer.floatChannelData![0]
            destination.update(from: samples + at, count: head)
            (destination + head).update(from: samples, count: frames - head)
            buffer.frameLength = AVAudioFrameCount(frames)
            framesPopped.store(start + frames, ordering: .releasing)
        }
        popped.store(next + 1, ordering: .releasing)
        return entry
    }

    private func claim() -> Int? {
        let next = pushed.load(ordering: .relaxed)
        return next - popped.load(ordering: .acquiring) < entryCapacity ? next : nil
    }

    private func publish(_ entry: Entry, at slot: Int) {
        entries[slot % entryCapacity] = entry
        pushed.store(slot + 1, ordering: .releasing)
    }

    private func drop() {
        droppedCount.add(1, ordering: .relaxed)
    }
}
