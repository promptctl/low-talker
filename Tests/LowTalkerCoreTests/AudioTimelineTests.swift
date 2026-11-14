import LowTalkerCore
import Testing
import Uptime

@Suite struct AudioTimelineTests {
    private let origin = HostTime(uptime: .zero)

    /// The moment `count` samples after the origin, at the pipeline rate.
    private func after(_ count: Int) -> HostTime { origin + .seconds(AudioClip.duration(for: count)) }

    @Test func aMomentAtTheAnchorIsTheAnchorsPosition() {
        var timeline = AudioTimeline(startingAt: origin)
        #expect(timeline.position(at: origin) == 0)
        timeline.mark(1_600, at: after(1_600))
        #expect(timeline.position(at: after(1_600)) == 1_600)
    }

    /// Both directions from the anchor, since a key-down can be stamped before the
    /// newest buffer or after it.
    @Test func momentsEitherSideOfTheAnchorCountSamplesFromIt() {
        var timeline = AudioTimeline(startingAt: origin)
        timeline.mark(1_000, at: after(1_000))
        #expect(timeline.position(at: after(1_240)) == 1_240)
        #expect(timeline.position(at: after(600)) == 600)
    }

    /// Nothing clamps: a moment before the first sample answers a position that never
    /// existed, and what a ring still holds is the ring's business, not this one's.
    @Test func aMomentBeforeTheFirstSampleAnswersBeforeTheFirstPosition() {
        let timeline = AudioTimeline(startingAt: after(400))
        #expect(timeline.position(at: origin) == -400)
    }

    /// Only the newest stamp is kept, so drift between the device's clock and the
    /// host's never accumulates: a later mark decides every answer after it.
    @Test func aLaterMarkReplacesTheAnchorItDoesNotAverageWithIt() {
        var timeline = AudioTimeline(startingAt: origin)
        timeline.mark(16_000, at: after(16_000))
        // The device ran 100 samples slow: position 32,000 arrives where 31,900 was due.
        timeline.mark(32_000, at: after(31_900))
        #expect(timeline.position(at: after(31_900)) == 32_000)
        #expect(timeline.position(at: after(31_800)) == 31_900)
    }
}
