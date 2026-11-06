@testable import LowTalkerCore
import Testing

/// The gate's judgement of one frame, with no actor and no clips: what sounds, what the room and
/// the discriminator refused, and what no room heard held to the range alone.
@Suite struct JudgementTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let peak: Float
        let verdict: Verdict
        /// The range: the loudest syllable of frames called speech, none while zero.
        var range: Float = 0
        /// The peak of the run the frame may carry on, none while zero.
        var run: Float = 0
        var room: Float?
        var opensBurst = false
        let sounds: Bool
        var refusal = Judgement.Refusal.none
        var keptOut: Float?

        var testDescription: String { name }
    }

    static let cases = [
        Case(name: "a loud frame called speech sounds", peak: 0.5, verdict: .speech, sounds: true),
        Case(
            name: "a loud frame called other sounds at a speaker's level, and is kept out of the range",
            peak: 0.5, verdict: .other, sounds: true, keptOut: 0.5
        ),
        Case(
            name: "before a speaker, a soft frame clear of the room that is not called speech is refused as not speech",
            peak: 0.005, verdict: .other, room: 0.001, sounds: false, refusal: .asNotSpeech
        ),
        Case(
            name: "before a speaker, a soft frame inside the room is no refusal of the discriminator's",
            peak: 0.005, verdict: .other, room: 0.004, sounds: false
        ),
        Case(
            name: "a soft frame called speech sounds before any speaker, whatever the room reads",
            peak: 0.005, verdict: .speech, room: 0.004, sounds: true
        ),
        Case(
            name: "after a speaker, a soft frame within 10 dB of the room is refused as room",
            peak: 0.005, verdict: .other, range: 0.05, room: 0.004, sounds: false, refusal: .asRoom
        ),
        Case(
            name: "after a speaker, a soft frame called speech inside the room still sounds",
            peak: 0.005, verdict: .speech, range: 0.05, room: 0.004, sounds: true
        ),
        Case(
            name: "after a speaker, a soft frame clear of the room sounds as a soft consonant does",
            peak: 0.005, verdict: .other, range: 0.05, room: 0.001, sounds: true
        ),
        Case(
            name: "a frame 54 dB under the range is outside it and refused by neither",
            peak: 0.001, verdict: .other, range: 0.5, room: 0.0001, sounds: false
        ),
        Case(
            name: "a frame just over a sixteenth of the range, 23.9 dB under, is within it",
            peak: 0.032, verdict: .other, range: 0.5, room: 0.0001, sounds: true
        ),
        Case(
            name: "a frame exactly a sixteenth of the range, 24.08 dB under, is outside it",
            peak: 0.03125, verdict: .other, range: 0.5, room: 0.0001, sounds: false
        ),
        Case(
            name: "the run a frame carries on sets the loudest it is judged against, as the range does",
            peak: 0.005, verdict: .other, run: 0.5, room: 0.0001, sounds: false
        ),
        Case(name: "digital silence stands within range of nothing", peak: 0, verdict: .other, sounds: false),
        Case(
            name: "a frame louder than the range that is not called speech is kept out of it",
            peak: 0.9, verdict: .other, range: 0.1, room: 0.001, sounds: true, keptOut: 0.9
        ),
    ]

    @Test(arguments: cases) func aFrameIsJudgedByWhatItIs(_ c: Case) {
        let judged = Judgement(peak: c.peak, verdict: c.verdict, range: c.range, run: c.run, room: c.room, opensBurst: c.opensBurst)
        #expect(judged.sounds == c.sounds)
        #expect(judged.refusal == c.refusal)
        #expect(judged.keptOut == c.keptOut)
    }

    @Test func noRoomHeardIsRecordedAsRoomless() {
        let alone = Judgement(peak: 0.5, verdict: .speech, range: 0, run: 0, room: nil, opensBurst: false)
        let heard = Judgement(peak: 0.5, verdict: .speech, range: 0, run: 0, room: 0.001, opensBurst: false)
        #expect(alone.roomless)
        #expect(!heard.roomless)
    }

    @Test func theFrameThatOpensABurstWithNoRoomHeardIsItsOwnRoom() {
        // One soft frame called speech, no room read: nothing in it stands clear of itself, so a
        // run in it must reach `audible`; the frames after it have no room at all.
        let opening = Judgement(peak: 0.005, verdict: .speech, range: 0, run: 0, room: nil, opensBurst: true)
        let carrying = Judgement(peak: 0.005, verdict: .speech, range: 0, run: 0, room: nil, opensBurst: false)
        #expect(opening.softest == SpeechGate.audible)
        #expect(carrying.softest == 0.005 / SpeechGate.dynamicRange)
    }
}
