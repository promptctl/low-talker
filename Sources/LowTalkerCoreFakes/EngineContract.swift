import Foundation
import LowTalkerCore
import Synchronization
import TestProbes

/// The engine port's semantics, stated once. Each statement runs one engine through `Transcriber`
/// and `EngineTurns` alone and says every way it disagreed; nothing, when it agreed. The fake runs
/// it in `make test`, and so can `WhisperKitTranscriber` wherever it can run inside the suite,
/// since a subject is only an engine, audio it hears words in, and a vocabulary it refuses.
/// [LAW:one-source-of-truth]
public struct EngineContract: Sendable {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// Any number of partials, then one final, and no partial once it has returned; and audio
        /// said to hold speech is heard as words.
        case partialsThenOneFinal
        /// Partials come in the order heard: each one's confirmed words begin with the previous
        /// one's, and the final transcript begins with the last of them, the promise
        /// `ConfirmedCursor` reads.
        case confirmedWordsOpenTheTranscript
        /// The vocabulary is told before anything is heard: one the engine cannot carry fails
        /// `.vocabulary` with no clip taken from the audio.
        case aRefusedVocabularyHearsNothing
        /// A served decode asked for under an open hold waits, while a dictation decode runs, and
        /// is answered once the hold lets go, counted as deferred.
        case aServedDecodeWaitsForTheHold
        /// A served caller cancelled while it waits on a hold fails `.cancelled`.
        case aServedCallerCancelledWhileWaitingFailsCancelled

        public var description: String {
            switch self {
            case .partialsThenOneFinal: "partials, then one final"
            case .confirmedWordsOpenTheTranscript: "confirmed words only grow and open the transcript"
            case .aRefusedVocabularyHearsNothing: "a refused vocabulary hears nothing"
            case .aServedDecodeWaitsForTheHold: "a served decode waits for the hold"
            case .aServedCallerCancelledWhileWaitingFailsCancelled: "a served caller cancelled while waiting fails cancelled"
            }
        }
    }

    /// The engine under test loaded on `turns`: hearing for dictation, and the same engine for
    /// served callers.
    public let engine: @Sendable (_ turns: EngineTurns) async throws -> (dictation: any Transcriber, served: any Transcriber)
    /// Audio the engine hears words in, streamed to it a microphone buffer at a time.
    public let speech: AudioClip
    /// A vocabulary the engine cannot carry.
    public let refused: Vocabulary

    public init(engine: @escaping @Sendable (_ turns: EngineTurns) async throws -> (dictation: any Transcriber, served: any Transcriber), speech: AudioClip, refused: Vocabulary) {
        self.engine = engine
        self.speech = speech
        self.refused = refused
    }

    /// Seconds of audio a microphone buffer hands over.
    static let buffer: TimeInterval = 0.1

    public func disagreements(with statement: Statement) async throws -> [String] {
        let changes = Changes()
        let turns = EngineTurns(onReadingChanged: { changes.note() })
        let (dictation, served) = try await engine(turns)
        switch statement {
        case .partialsThenOneFinal:
            let heard = await hear(on: dictation)
            guard case .success(let transcript) = heard.final else { return ["the speech failed: \(heard.final)"] }
            return (heard.afterFinal == 0 ? [] : ["\(heard.afterFinal) partials came after the final"])
                + (transcript.words.isEmpty ? ["the speech was heard as no words"] : [])
        case .confirmedWordsOpenTheTranscript:
            let heard = await hear(on: dictation)
            guard case .success(let transcript) = heard.final else { return ["the speech failed: \(heard.final)"] }
            let confirmed = heard.partials.map(\.confirmed)
            return zip([Transcript(words: [])] + confirmed, confirmed).compactMap { Self.confirming($1, after: $0) }
                + [Self.ending(transcript, after: confirmed.last ?? Transcript(words: []))].compactMap { $0 }
        case .aRefusedVocabularyHearsNothing:
            let pulls = Pulls()
            let result = await Result { () async throws(TranscriptionFailure) in
                try await dictation.transcribe(Counted(clips: speech.chunks(of: Self.buffer), pulls: pulls), expecting: refused, partial: { _ in })
            }
            guard case .failure(.vocabulary) = result else { return ["the refused vocabulary was answered \(result)"] }
            return pulls.count == 0 ? [] : ["the engine took \(pulls.count) clips before refusing the vocabulary"]
        case .aServedDecodeWaitsForTheHold:
            let hold = turns.hold()
            let asked = served.answering(speech, changes: changes)
            await changes.settled { turns.reading.waiting == 1 || asked.answer != nil }
            let held = asked.answer.map { ["the served decode was answered under the hold: \($0)"] } ?? []
            let spoken = await Result { () async throws(TranscriptionFailure) in try await dictation.transcribe(speech, expecting: .empty) }
            let waited = turns.reading.waiting == 1 && asked.answer == nil
            hold.release()
            await changes.settled { asked.answer != nil }
            return held
                + (spoken.isSuccess ? [] : ["the dictation decode under the hold failed: \(spoken)"])
                + (waited || !held.isEmpty ? [] : ["the served decode stopped waiting before the hold let go"])
                + (asked.answer?.isSuccess == true ? [] : ["the served decode, once the hold let go, was answered \(asked.answer.map { "\($0)" } ?? "never")"])
                + (turns.reading.tally.deferred == 1 ? [] : ["the turns counted \(turns.reading.tally.deferred) deferred decodes"])
        case .aServedCallerCancelledWhileWaitingFailsCancelled:
            let hold = turns.hold()
            defer { hold.release() }
            let asked = served.answering(speech, changes: changes)
            await changes.settled { turns.reading.waiting == 1 || asked.answer != nil }
            asked.task.cancel()
            await changes.settled { asked.answer != nil }
            guard case .failure(.cancelled) = asked.answer else { return ["the cancelled served caller was answered \(asked.answer.map { "\($0)" } ?? "never")"] }
            return []
        }
    }

    /// What is wrong with a pass confirming `now` after one confirmed `earlier`: nil when its
    /// confirmed words begin with the earlier ones. [LAW:single-enforcer] Statement 2's one
    /// reading, which the fake holds every configuration to as it runs.
    static func confirming(_ now: Transcript, after earlier: Transcript) -> String? {
        now.words.map(\.text).starts(with: earlier.words.map(\.text)) ? nil : "the confirmed words \(earlier.words.map(\.text)) were followed by \(now.words.map(\.text))"
    }

    /// What is wrong with a final transcript after the last partial confirmed `confirmed`: nil
    /// when it opens with them.
    static func ending(_ final: Transcript, after confirmed: Transcript) -> String? {
        final.words.map(\.text).starts(with: confirmed.words.map(\.text)) ? nil : "the final \(final.words.map(\.text)) does not open with the confirmed \(confirmed.words.map(\.text))"
    }

    /// The partials told for `speech` streamed a buffer at a time, how many came once the final
    /// had returned, and the final.
    private func hear(on engine: any Transcriber) async -> (partials: [Partial], afterFinal: Int, final: Result<Transcript, TranscriptionFailure>) {
        let told = Mutex<(partials: [Partial], returned: Bool, afterFinal: Int)>(([], false, 0))
        let clips = speech.chunks(of: Self.buffer)
        let final = await Result { () async throws(TranscriptionFailure) in
            try await engine.transcribe(Counted(clips: clips, pulls: Pulls()), expecting: .empty) { partial in
                told.withLock { told in
                    if told.returned { told.afterFinal += 1 } else { told.partials.append(partial) }
                }
            }.transcript
        }
        let heard = told.withLock { told in
            told.returned = true
            return told
        }
        return (heard.partials, heard.afterFinal, final)
    }
}

/// A transcribe running on a task of its own, so a statement can cancel it and read whether it
/// has been answered yet.
private final class Asked: Sendable {
    private final class Answered: Sendable {
        let result = Mutex<Result<Transcript, TranscriptionFailure>?>(nil)
    }

    private let answered = Answered()
    let task: Task<Void, Never>

    init(_ engine: any Transcriber, _ speech: AudioClip, changes: Changes) {
        let answered = answered
        task = Task {
            let result = await Result { () async throws(TranscriptionFailure) in try await engine.transcribe(speech, expecting: .empty).transcript }
            answered.result.withLock { $0 = result }
            changes.note()
        }
    }

    var answer: Result<Transcript, TranscriptionFailure>? { answered.result.withLock { $0 } }
}

private extension Transcriber {
    func answering(_ speech: AudioClip, changes: Changes) -> Asked {
        Asked(self, speech, changes: changes)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { true } else { false }
    }
}

/// How many clips have been taken from a `Counted`.
private final class Pulls: Sendable {
    private let taken = Mutex(0)
    var count: Int { taken.withLock { $0 } }
    func take() { taken.withLock { $0 += 1 } }
}

/// Clips handed over one at a time, counting each one taken.
private struct Counted: AsyncSequence, Sendable {
    typealias Element = AudioClip
    typealias Failure = Never

    let clips: [AudioClip]
    let pulls: Pulls

    struct AsyncIterator: AsyncIteratorProtocol {
        var rest: ArraySlice<AudioClip>
        let pulls: Pulls

        mutating func next() async -> AudioClip? {
            guard let clip = rest.popFirst() else { return nil }
            pulls.take()
            return clip
        }

        mutating func next(isolation actor: isolated (any Actor)?) async throws(Never) -> AudioClip? {
            await next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(rest: clips[...], pulls: pulls)
    }
}
