import LowTalkerCore
import Testing

@Suite struct AudioRingTests {
    @Test func retainsTheNewestSamplesAtAbsolutePositions() {
        var ring = AudioRing(capacity: 4)
        ring.append([1, 2, 3])
        ring.append([4, 5, 6])
        #expect(ring.end == 6)
        #expect(ring.retained == 2..<6)
        #expect(ring.clip(in: 2..<6).samples == [3, 4, 5, 6])
    }

    /// A position taken before a burst still names the same sample after it.
    @Test func positionsSurviveWrapping() {
        var ring = AudioRing(capacity: 5)
        ring.append([0, 1, 2])
        let mark = ring.end
        ring.append([3, 4, 5, 6])
        #expect(ring.clip(in: mark..<ring.end).samples == [3, 4, 5, 6])
    }

    @Test func burstLargerThanCapacityKeepsItsTail() {
        var ring = AudioRing(capacity: 3)
        ring.append((1...10).map(Float.init))
        #expect(ring.end == 10)
        #expect(ring.retained == 7..<10)
        #expect(ring.clip(in: 7..<10).samples == [8, 9, 10])
    }

    /// The ring grows as samples land, so a burst into one not yet full skips slots it never
    /// held - and still keeps exactly its tail.
    @Test func burstIntoAPartlyFilledRingKeepsItsTail() {
        var ring = AudioRing(capacity: 4)
        ring.append([1])
        ring.append((2...7).map(Float.init))
        #expect(ring.retained == 3..<7)
        #expect(ring.clip(in: 0..<7).samples == [4, 5, 6, 7])
        ring.append([8])
        #expect(ring.clip(in: 0..<8).samples == [5, 6, 7, 8])
    }

    /// Pre-roll before the first sample and positions that scrolled off both yield
    /// what exists, not an error.
    @Test func clipIsClampedToWhatIsRetained() {
        var ring = AudioRing(capacity: 4)
        ring.append([1, 2])
        #expect(ring.clip(in: -3..<2).samples == [1, 2])
        ring.append([3, 4, 5, 6])
        #expect(ring.clip(in: 0..<6).samples == [3, 4, 5, 6])
        #expect(ring.clip(in: 10..<12).samples.isEmpty)
        #expect(ring.clip(in: 3..<3).samples.isEmpty)
    }

    /// What the clamp cost, which the clip it returns cannot show. Samples the ring held
    /// and has since overwritten count; positions no sample ever took do not, however far
    /// the range reaches past them.
    @Test func scrolledOffIsWhatWasCapturedAndNoLongerHeld() {
        var ring = AudioRing(capacity: 4)
        ring.append([1, 2])
        #expect(ring.scrolledOff(from: -3..<2) == 0)
        ring.append([3, 4, 5, 6])
        #expect(ring.scrolledOff(from: 0..<6) == 2)
        #expect(ring.scrolledOff(from: -3..<6) == 2)
        #expect(ring.scrolledOff(from: 2..<6) == 0)
        #expect(ring.scrolledOff(from: 10..<12) == 0)
    }

    @Test func capacityFollowsThePipelineRate() {
        #expect(AudioRing(retaining: 1).capacity == Int(AudioClip.sampleRate))
        #expect(AudioRing(retaining: 60).retained.isEmpty)
    }
}
