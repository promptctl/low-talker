@testable import LowTalkerCore
import Foundation
import Testing

/// The range is set by speech alone: a sound the discriminator calls something else, however
/// loud, sets none, while what is kept and handed stays what the gate always handed.
@Suite struct UtteranceVerdictTests {
    static func level(_ level: Float, _ seconds: TimeInterval) -> [Float] {
        Array(repeating: level, count: AudioClip.sampleCount(for: seconds))
    }

    /// A cough, then quiet, then a speaker 25 dB under it: louder than the speaker by more than
    /// the range spans, so a cough that set the range would let all of the speech go.
    static let cough = level(0.9, 0.3)
    static let pause = level(0.001, 0.2)
    static let soft = level(0.05, 1)
    /// Anything as loud as the cough is called other.
    static let coughs = Verdicts.other(atOrAbove: 0.8)

    static func handed(_ samples: [Float], judging discriminator: any Discriminator) async throws -> (samples: [Float], quiet: Quiet) {
        let utterance = Utterance(judging: discriminator)
        for clip in AudioClip(samples: samples).chunks(of: 0.01) {
            try await utterance.append(clip)
        }
        try await utterance.end()
        let (handed, arrived, _, timeline) = await utterance.audio(beyond: 0)
        return (Array(handed.prefix(arrived)), timeline.quiet)
    }

    @Test func aCoughBeforeASoftSpeakerSetsNoRangeSoTheSpeechIsHanded() async throws {
        let audio = Self.cough + Self.pause + Self.soft
        let master = try await Self.handed(audio, judging: Verdicts.everyFrameSpeech)
        // A cough that sets the range lets the soft speech go, all but what its hangover carries.
        #expect(master.samples.filter { $0 == 0.05 }.count == Utterance.hangover - Self.pause.count)
        let (samples, quiet) = try await Self.handed(audio, judging: Self.coughs)
        #expect(samples.filter { $0 == 0.05 }.count == Self.soft.count)
        #expect(quiet.range == 0.05)
        #expect(quiet.keptOut == 0.9 && quiet.keptOutFrames == 3)
    }

    @Test func aKnockFitOfFiveSetsNoRangeSoTheSpeechAfterItIsHanded() async throws {
        let knock = Self.level(0.9, 0.15), gap = Self.level(0.001, 0.25)
        let fit = (0..<5).flatMap { _ in knock + gap }
        let (samples, quiet) = try await Self.handed(fit + Self.soft, judging: Self.coughs)
        #expect(samples.filter { $0 == 0.05 }.count == Self.soft.count)
        #expect(quiet.range == 0.05)
        #expect(quiet.keptOut == 0.9)
    }

    /// One word, then talk 27 dB under it: the word sets the range, and the talk stays outside it.
    @Test func backgroundTalkAfterAOneWordPressIsRefused() async throws {
        let word = Self.level(0.5, 0.3)
        let talk = Self.level(0.5 * Float(pow(10, -27.0 / 20)), 2)
        let (samples, quiet) = try await Self.handed(word + Self.pause + talk, judging: Verdicts.everyFrameSpeech)
        #expect(samples.count == word.count + Utterance.hangover)
        #expect(quiet.range == 0.5 && quiet.keptOut == nil && quiet.keptOutFrames == 0)
    }

    /// The room after a cough is judged as the same room alone is: what decides whether a sound
    /// is handed is the gate's, not the discriminator's.
    @Test func theRoomAfterACoughIsJudgedAsTheRoomAlone() async throws {
        let room = Self.level(0.0178, 3)
        let alone = try await Self.handed(room, judging: Self.coughs)
        let after = try await Self.handed(Self.cough + room, judging: Self.coughs)
        #expect(after.samples.count == Self.cough.count + alone.samples.count)
    }

    /// A loud frame called other inside speech is kept with the speech, and sets no range.
    @Test func aLoudFrameCalledOtherInsideSpeechIsHandedAndSetsNoRange() async throws {
        let speech = Self.level(0.1, 0.3)
        let audio = speech + Self.level(0.9, 0.1) + speech
        let (samples, quiet) = try await Self.handed(audio, judging: Self.coughs)
        #expect(samples == audio)
        #expect(quiet.range == 0.1)
        #expect(quiet.keptOut == 0.9 && quiet.keptOutFrames == 1)
    }

    /// No pass is handed a frame before the audio its verdict reads has arrived, and the end
    /// judges the frames still waiting.
    @Test func aFrameWaitsForItsLookahead() async throws {
        let utterance = Utterance(judging: Verdicts.other(atOrAbove: 0.8, lookahead: AudioClip.sampleCount(for: 0.2)))
        try await utterance.append(AudioClip(samples: Self.level(0.5, 0.3)))
        let early = await utterance.audio(beyond: 0)
        #expect(early.arrived == Utterance.frameCount)
        try await utterance.end()
        #expect(await utterance.audio(beyond: 0).arrived == 3 * Utterance.frameCount)
    }

    struct Unanswerable: Discriminator {
        struct Failure: Error {}
        let lookbehind = 0, lookahead = 0
        func verdict(_ window: ArraySlice<Float>) throws -> Verdict { throw Failure() }
    }

    /// A discriminator that cannot answer fails the utterance as the engine, and a pass waiting
    /// on its speech is woken rather than left waiting.
    @Test func aDiscriminatorThatCannotAnswerFailsTheFillAndWakesTheWait() async throws {
        let utterance = Utterance(judging: Unanswerable())
        async let waiting = utterance.audio(beyond: 0)
        await #expect {
            try await utterance.fill(from: AsyncStream { feed in
                feed.yield(AudioClip(samples: Self.level(0.5, 0.3)))
                feed.finish()
            })
        } throws: { error in
            guard case TranscriptionFailure.engine(let cause) = error else { return false }
            return cause is Unanswerable.Failure
        }
        #expect(await waiting.ended)
    }
}
