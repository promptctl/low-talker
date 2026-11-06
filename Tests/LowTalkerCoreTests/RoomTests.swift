@testable import LowTalkerCore
import Testing

/// The room a frame stands clear of, read frame by frame with no actor.
@Suite struct RoomTests {
    static func frame(_ level: Float, count: Int = SpeechGate.frameCount) -> AudioClip {
        AudioClip(samples: Array(repeating: level, count: count))
    }

    @Test func aFrameNotCalledSpeechIsItsOwnReadingAndTheRoomUntilQuieterIsHeard() {
        var room = Room()
        let first = room.hear(Self.frame(0.004), .other)
        #expect(first.reading == 0.004)
        #expect(first.against == 0.004)
        #expect(room.hear(Self.frame(0.002), .other).against == 0.002)
        #expect(room.hear(Self.frame(0.003), .other).against == 0.002)
    }

    @Test func aFrameCalledSpeechIsNoReadingAndHasNoRoomUntilOneIsHeard() {
        var room = Room()
        let word = room.hear(Self.frame(0.005), .speech)
        #expect(word.reading == nil)
        #expect(word.against == nil)
    }

    @Test func digitalSilenceAndAShortFrameGiveNoReading() {
        var room = Room()
        #expect(room.hear(Self.frame(0), .other).reading == nil)
        #expect(room.hear(Self.frame(0.003, count: SpeechGate.frameCount - 1), .other).reading == nil)
    }

    @Test func aReadingAgesOutAfterTheRoomSpanHasPassedInFramesThatGiveNone() {
        var room = Room()
        _ = room.hear(Self.frame(0.002), .other)
        let frames = Int((SpeechGate.roomSpan / SpeechGate.frame).rounded())
        let last = (1...frames).map { _ in room.hear(Self.frame(0.5), .speech).against }.last
        #expect(last == 0.002)
        #expect(room.hear(Self.frame(0.5), .speech).against == nil)
    }
}
