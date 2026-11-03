/// The most recent `capacity` pipeline samples, addressed by absolute position.
///
/// Positions count every sample ever appended, so a caller can take a position now,
/// keep appending, and slice by that position later: a session is two positions on
/// the ring, not a start and stop of the microphone. Only the newest `capacity`
/// samples are retained; older positions have scrolled off.
///
/// [LAW:effects-at-boundaries] A value with no clock and no thread: the capture
/// engine owns the one that receives the microphone, tests fill one by hand.
public struct AudioRing: Sendable, Equatable {
    public let capacity: Int
    private var storage: [Float]
    /// One past the newest sample: the position the next appended sample will take.
    public private(set) var end = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "a ring must retain at least one sample")
        self.capacity = capacity
        // Grown as samples land rather than filled up front: no position before `end` is
        // ever read, and zeroing a minute of samples cost every capture made on the main
        // actor its first ~100 ms - seconds across a test suite on a 3-core runner
        // (low-unfiled-50ff.cis).
        // Reserved, not filled: allocated once, so the ring never copies itself as it grows.
        storage = []
        storage.reserveCapacity(capacity)
    }

    public init(retaining duration: Double) {
        self.init(capacity: AudioClip.sampleCount(for: duration))
    }

    /// The positions still held: at most `capacity` of them, ending at `end`.
    public var retained: Range<Int> { max(0, end - capacity)..<end }

    public mutating func append(_ samples: [Float]) {
        // Only the newest `capacity` samples can survive; the positions of the rest
        // still advance `end`, so a position taken before a long burst stays true.
        let kept = samples.suffix(capacity)
        var position = end + samples.count - kept.count
        for sample in kept {
            let slot = position % capacity
            if slot < storage.count {
                storage[slot] = sample
            } else {
                // A burst past the capacity skips positions the ring never held; their slots
                // are filled before the one written, and overwritten before they are read.
                storage.append(contentsOf: repeatElement(0, count: slot - storage.count))
                storage.append(sample)
            }
            position += 1
        }
        end += samples.count
    }

    /// The samples at the positions in `range` that are still retained; positions
    /// that scrolled off or are not yet written contribute nothing, so a session
    /// that began before the ring filled, or whose pre-roll reaches before the first
    /// sample, yields what exists rather than failing. What the clamp cost is
    /// `scrolledOff(from:)`, since a shorter clip looks like no other clip.
    public func clip(in range: Range<Int>) -> AudioClip {
        let held = range.clamped(to: retained)
        return AudioClip(samples: held.map { storage[$0 % capacity] })
    }

    /// How many samples of `range` the ring held once and no longer does: what
    /// `clip(in:)` clamped away at the head. Positions no sample ever took are not among
    /// them - a pre-roll reaching back before the first sample reaches over audio that
    /// never existed, which is the ordinary state of the first session after a start.
    ///
    /// [LAW:parse-dont-validate] The clamp is where a caller's range quietly becomes a
    /// shorter one, and the clip it returns carries no sign of it. This is the proof the
    /// clamp discards, kept so a session can tell a whole capture from a truncated one.
    public func scrolledOff(from range: Range<Int>) -> Int {
        range.clamped(to: 0..<end).count - range.clamped(to: retained).count
    }
}
