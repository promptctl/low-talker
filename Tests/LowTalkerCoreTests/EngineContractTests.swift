import Foundation
import LowTalkerCore
import LowTalkerCoreFakes
import Testing

/// The one fake engine keeps every statement of the engine's contract, which is what makes the
/// suites built on it worth trusting; an engine that breaks a statement is told it did, and the
/// fake refuses to be configured as one.
@Suite struct EngineContractTests {
    /// A second of tone: loud enough to be heard, a buffer at a time.
    static let speech = AudioClip(samples: (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / AudioClip.sampleRate)) })
    static let words = Transcript(typed: " one two three four")
    static let refused = Vocabulary([try! Vocabulary.Term("Kubernetes")])

    /// The fake as a streaming engine: a word confirmed per quarter second heard, up to half of
    /// them, the rest read tentatively, and any vocabulary with a term in it refused.
    static let fake = EngineContract(engine: { turns in
        let engine = FakeTranscriber(
            reading: { samples in Transcript(words: Array(words.words.dropFirst(confirmed(samples)))) },
            confirming: { samples in Transcript(words: Array(words.words.prefix(confirmed(samples)))) },
            refusing: { vocabulary throws(VocabularyError) in
                if !vocabulary.terms.isEmpty { throw .tooLong(tokens: 300, limit: 224) }
            },
            turns: turns
        ) { _ in words }
        return (engine, engine.served)
    }, speech: speech, refused: refused)

    private static func confirmed(_ samples: [Float]) -> Int {
        min(words.words.count / 2, Int(AudioClip(samples: samples).duration / 0.25))
    }

    @Test(.timeLimit(.minutes(1)), arguments: EngineContract.Statement.allCases)
    func theFakeKeepsTheStatement(_ statement: EngineContract.Statement) async throws {
        #expect(try await Self.fake.disagreements(with: statement) == [])
    }

    /// The statements a subject of this file's own breaks, so the contract is seen to tell.
    static func subject(_ engine: any Transcriber) -> EngineContract {
        EngineContract(engine: { _ in (engine, engine) }, speech: speech, refused: refused)
    }

    @Test func confirmedWordsThatShrinkDisagree() async throws {
        #expect(try await Self.subject(Shrinking()).disagreements(with: .confirmedWordsOpenTheTranscript) != [])
    }

    @Test func aFinalThatDoesNotOpenWithTheConfirmedWordsDisagrees() async throws {
        #expect(try await Self.subject(Unopened()).disagreements(with: .confirmedWordsOpenTheTranscript) != [])
    }

    @Test func aVocabularyRefusedAfterHearingDisagrees() async throws {
        #expect(try await Self.subject(RefusingLate()).disagreements(with: .aRefusedVocabularyHearsNothing) != [])
    }

    @Test func anEngineThatIgnoresTurnsDisagrees() async throws {
        #expect(try await Self.subject(Turnless()).disagreements(with: .aServedDecodeWaitsForTheHold) != [])
        #expect(try await Self.subject(Turnless()).disagreements(with: .aServedCallerCancelledWhileWaitingFailsCancelled) != [])
    }

    /// The fake fails the test that configures it as an engine that cannot exist.
    @Test func theFakeRefusesConfirmedWordsThatShrink() async throws {
        let engine = FakeTranscriber(confirming: { samples in Transcript(typed: samples.count > 1_600 ? " one" : " one two") }) { _ in Self.words }
        await withKnownIssue { _ = try? await engine.transcribe(Buffers.stream(Self.speech), expecting: .empty, partial: { _ in }) }
    }

    @Test func theFakeRefusesAFinalThatDoesNotOpenWithItsConfirmedWords() async throws {
        let engine = FakeTranscriber(confirming: { _ in Transcript(typed: " two") }) { _ in Self.words }
        await withKnownIssue { _ = try? await engine.transcribe(Self.speech, expecting: .empty) }
    }

    @Test func theFakeRefusesAVocabularyRefusedAfterHearing() async throws {
        let engine = FakeTranscriber { _ throws(TranscriptionFailure) in throw .vocabulary(.tooLong(tokens: 300, limit: 224)) }
        await withKnownIssue { _ = try? await engine.transcribe(Self.speech, expecting: Self.refused) }
    }
}

/// Clips a buffer at a time, as a microphone hands them over.
private enum Buffers {
    static func stream(_ clip: AudioClip) -> AsyncStream<AudioClip> {
        AsyncStream { continuation in
            clip.chunks(of: 0.1).forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

/// Confirms two words, then one.
private struct Shrinking: Transcriber {
    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        var passes = 0
        for await _ in audio {
            passes += 1
            partial(Partial(confirmed: Transcript(typed: passes == 1 ? " one two" : " one"), tentative: Transcript(words: []), repunctuated: 0, unread: nil))
        }
        return Transcription(transcript: EngineContractTests.words, quiet: .none)
    }
}

/// Confirms a word its final does not begin with.
private struct Unopened: Transcriber {
    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        for await _ in audio {
            partial(Partial(confirmed: Transcript(typed: " two"), tentative: Transcript(words: []), repunctuated: 0, unread: nil))
        }
        return Transcription(transcript: EngineContractTests.words, quiet: .none)
    }
}

/// Hears the audio out before refusing the vocabulary.
private struct RefusingLate: Transcriber {
    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        for await _ in audio {}
        throw .vocabulary(.tooLong(tokens: 300, limit: 224))
    }
}

/// Answers at once, whoever holds the engine.
private struct Turnless: Transcriber {
    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        for await _ in audio {}
        return Transcription(transcript: EngineContractTests.words, quiet: .none)
    }
}
