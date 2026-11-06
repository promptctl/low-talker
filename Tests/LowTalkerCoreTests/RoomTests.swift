@testable import LowTalkerCore
import Testing

/// The room a frame stands clear of, read frame by frame with no actor.
@Suite struct RoomTests {
    static func frame(_ level: Float, count: Int = SpeechGate.frameCount) -> AudioClip {
        AudioClip(samples: Array(repeating: level, count: count))
    }

    static func hear(_ room: inout Room, _ frame: AudioClip, _ verdict: Verdict) -> (against: Float?, reading: Float?) {
        room.hear(samples: frame.samples.count, peak: frame.peak, verdict)
    }

    @Test func aFrameNotCalledSpeechIsItsOwnReadingAndTheRoomUntilQuieterIsHeard() {
        var room = Room()
        let first = Self.hear(&room, Self.frame(0.004), .other)
        #expect(first.reading == 0.004)
        #expect(first.against == 0.004)
        #expect(Self.hear(&room, Self.frame(0.002), .other).against == 0.002)
        #expect(Self.hear(&room, Self.frame(0.003), .other).against == 0.002)
    }

    @Test func aFrameCalledSpeechIsNoReadingAndHasNoRoomUntilOneIsHeard() {
        var room = Room()
        let word = Self.hear(&room, Self.frame(0.005), .speech)
        #expect(word.reading == nil)
        #expect(word.against == nil)
    }

    @Test func digitalSilenceAndAShortFrameGiveNoReading() {
        var room = Room()
        #expect(Self.hear(&room, Self.frame(0), .other).reading == nil)
        #expect(Self.hear(&room, Self.frame(0.003, count: SpeechGate.frameCount - 1), .other).reading == nil)
    }

    @Test func aReadingAgesOutAfterTheRoomSpanHasPassedInFramesThatGiveNone() {
        var room = Room()
        _ = Self.hear(&room, Self.frame(0.002), .other)
        let frames = Int((SpeechGate.roomSpan / SpeechGate.frame).rounded())
        let last = (1...frames).map { _ in Self.hear(&room, Self.frame(0.5), .speech).against }.last
        #expect(last == 0.002)
        #expect(Self.hear(&room, Self.frame(0.5), .speech).against == nil)
    }
}
