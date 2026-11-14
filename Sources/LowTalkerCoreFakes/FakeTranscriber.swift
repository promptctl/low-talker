import LowTalkerCore
import Synchronization
import TestProbes
import Testing

/// The one fake of the engine port: an engine that answers however the test configures it, and
/// keeps a log of everything it was given to hear. Scripted words, partials, a refusal, a failure,
/// a wait on a gate and a turn held are all values handed to it, so every caller's tests run on
/// one engine whose semantics `EngineContract` states. [LAW:one-type-per-behavior]
///
/// It hears as the real engine does where a caller can tell: the vocabulary is refused, if at
/// all, before any audio is taken in; a pass runs per clip as it arrives; and the final answer is
/// decoded through `turns` as `caller`, so holds and served callers meet the real turn rules.
/// A configuration that would make it an engine `EngineContract` says cannot exist - confirmed
/// words that shrink, a final that does not open with them, a vocabulary refused once audio was
/// taken - fails the test that built it. [LAW:no-silent-failure]
public final class FakeTranscriber: Transcriber {
    /// One utterance as far as the fake has heard it.
    public struct Heard: Sendable {
        public let vocabulary: Vocabulary
        /// Utterances the fake had answered when this one began.
        public let answeredBefore: Int
        public fileprivate(set) var samples: [Float] = []
        public fileprivate(set) var clips = 0
        /// Whether its audio has ended, and whether the caller had been cancelled by then.
        public fileprivate(set) var ended = false
        public fileprivate(set) var cancelled = false
    }

    /// [LAW:one-source-of-truth] One log `served` shares, so either engine says what both heard.
    private final class Log: Sendable {
        struct State {
            var utterances: [Heard] = []
            var answered = 0
            var changes: Changes?
        }

        let state = Mutex(State())

        func update<T>(_ body: (inout State) -> T) -> T {
            let (result, changes) = state.withLock { state in (body(&state), state.changes) }
            changes?.note()
            return result
        }
    }

    private let log: Log
    private let reading: @Sendable ([Float]) -> Transcript
    private let confirming: @Sendable ([Float]) -> Transcript
    private let repunctuating: @Sendable ([Float]) -> Int
    private let unreading: @Sendable ([Float]) -> Partial.Unread?
    private let missedAtKeyUp: Partial.Unread?
    private let quiet: Quiet
    private let refusing: @Sendable (Vocabulary) throws(VocabularyError) -> Void
    private let turns: EngineTurns
    private let caller: EngineTurns.Caller
    private let answer: @Sendable (AudioClip) async throws(TranscriptionFailure) -> Transcript

    /// `reading` is what a pass makes of the audio so far and `confirming` the words two passes
    /// have agreed on, which the answer has to begin with, `repunctuating` how many passes so far
    /// changed a settled word's punctuation, and `unreading` the passes the engine failed to read
    /// and why the latest did; one pass runs per clip as it arrives, and reads and confirms
    /// nothing unless a test says otherwise. A pass the key came up during that the engine failed
    /// to read is told as `missedAtKeyUp`, once the audio has ended. `refusing` throws for a
    /// vocabulary the engine cannot carry. `answer` is the final reading of the whole clip, told
    /// with `quiet`, and runs as a decode on `turns`.
    public init(
        reading: @escaping @Sendable ([Float]) -> Transcript = { _ in Transcript(typed: "") },
        confirming: @escaping @Sendable ([Float]) -> Transcript = { _ in Transcript(typed: "") },
        repunctuating: @escaping @Sendable ([Float]) -> Int = { _ in 0 },
        unreading: @escaping @Sendable ([Float]) -> Partial.Unread? = { _ in nil },
        missedAtKeyUp: Partial.Unread? = nil,
        quiet: Quiet = .none,
        refusing: @escaping @Sendable (Vocabulary) throws(VocabularyError) -> Void = { _ in },
        turns: EngineTurns = EngineTurns(),
        _ answer: @escaping @Sendable (AudioClip) async throws(TranscriptionFailure) -> Transcript
    ) {
        self.reading = reading
        self.confirming = confirming
        self.repunctuating = repunctuating
        self.unreading = unreading
        self.missedAtKeyUp = missedAtKeyUp
        self.quiet = quiet
        self.refusing = refusing
        self.turns = turns
        self.answer = answer
        caller = .dictation
        log = Log()
    }

    private init(_ engine: FakeTranscriber, as caller: EngineTurns.Caller) {
        reading = engine.reading
        confirming = engine.confirming
        repunctuating = engine.repunctuating
        unreading = engine.unreading
        missedAtKeyUp = engine.missedAtKeyUp
        quiet = engine.quiet
        refusing = engine.refusing
        turns = engine.turns
        answer = engine.answer
        log = engine.log
        self.caller = caller
    }

    /// The same engine, hearing for callers the server answers, as `WhisperKitTranscriber.served`.
    public var served: FakeTranscriber {
        FakeTranscriber(self, as: .served)
    }

    /// Moves `changes` whenever the log does, so a test awaits the engine hearing something
    /// instead of polling for it. [LAW:no-ambient-temporal-coupling]
    public func noting(_ changes: Changes) {
        log.update { $0.changes = changes }
    }

    /// Every utterance begun, in order, each as far as it has been heard.
    public var utterances: [Heard] { log.state.withLock { $0.utterances } }
    /// Every utterance whose audio has ended, each as the one clip its audio added up to.
    public var clips: [AudioClip] { utterances.filter(\.ended).map { AudioClip(samples: $0.samples) } }
    /// What each utterance was heard expecting, in the order they were begun.
    public var expected: [Vocabulary] { utterances.map(\.vocabulary) }
    /// The audio of the latest utterance, as far as it has arrived and been read.
    public var hearing: [Float] { utterances.last?.samples ?? [] }

    public func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        do throws(VocabularyError) { try refusing(vocabulary) } catch { throw .vocabulary(error) }
        let index = log.update { state in
            state.utterances.append(Heard(vocabulary: vocabulary, answeredBefore: state.answered))
            return state.utterances.count - 1
        }
        var samples: [Float] = []
        var confirmed = Transcript(words: [])
        for await clip in audio {
            samples += clip.samples
            let heard = pass(over: samples, unread: unreading(samples))
            if let broken = EngineContract.confirming(heard.confirmed, after: confirmed) { Issue.record("the fake broke the engine's contract: \(broken)") }
            confirmed = heard.confirmed
            partial(heard)
            log.update { state in
                state.utterances[index].samples = samples
                state.utterances[index].clips += 1
            }
        }
        missedAtKeyUp.map { partial(pass(over: samples, unread: $0)) }
        log.update { state in
            state.utterances[index].ended = true
            state.utterances[index].cancelled = Task.isCancelled
        }
        let clip = AudioClip(samples: samples)
        let answer = answer
        // [LAW:single-enforcer] The turn rules are `EngineTurns`'; a decode a hold cancelled
        // fails, as the real engine's does, and is run again.
        let turns = turns, caller = caller
        let answered = await Result { () async throws(TranscriptionFailure) in
            try await turns.decode(as: caller) { () async throws(TranscriptionFailure) in
                    let transcript = try await answer(clip)
                if Task.isCancelled { throw .cancelled }
                return transcript
            }
        }
        if case .failure(.vocabulary(let refusal)) = answered {
            Issue.record("the fake refused its vocabulary (\(refusal)) after hearing the audio; a vocabulary is refused through `refusing`, before any is taken")
        }
        if case .success(let transcript) = answered, let broken = EngineContract.ending(transcript, after: confirmed) {
            Issue.record("the fake broke the engine's contract: \(broken)")
        }
        log.update { $0.answered += 1 }
        return Transcription(transcript: try answered.get(), quiet: quiet)
    }

    private func pass(over samples: [Float], unread: Partial.Unread?) -> Partial {
        Partial(confirmed: confirming(samples), tentative: reading(samples), repunctuated: repunctuating(samples), unread: unread)
    }
}
