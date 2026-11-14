import Foundation
import Uptime

/// Where a ring's positions sit in time: the capture time of one known sample, which
/// places every other, since samples arrive at a fixed rate. It turns the moment a
/// key went down into the position the microphone had reached by then.
///
/// [LAW:effects-at-boundaries] A value with no clock and no ring: it is told when a
/// sample was captured and answers where a moment falls, so a test drives it with
/// times of its choosing.
public struct AudioTimeline: Sendable, Equatable {
    /// The one sample whose capture time is known; every answer is measured from it.
    private struct Anchor: Equatable {
        var position: Int
        var time: HostTime
    }

    private var anchor: Anchor

    /// A timeline whose first sample is expected at `time`. Nothing has been captured
    /// yet, so that is a prediction; the first buffer replaces it with a measurement.
    public init(startingAt time: HostTime) {
        anchor = Anchor(position: 0, time: time)
    }

    /// The sample at `position` was captured at `time`. Only the newest buffer's stamp
    /// is kept: measuring every moment from the newest one means the input device's
    /// drift against the host clock never accumulates. [LAW:one-source-of-truth]
    public mutating func mark(_ position: Int, at time: HostTime) {
        anchor = Anchor(position: position, time: time)
    }

    /// Where `moment` falls among the positions. A moment before the anchor answers a
    /// smaller position and one after it a larger, neither clamped to what a ring
    /// still holds: which of these positions still exist is the ring's own business.
    public func position(at moment: HostTime) -> Int {
        anchor.position + AudioClip.sampleCount(for: (moment - anchor.time).seconds)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
