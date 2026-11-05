import Dictation
import Foundation
import LowTalkerCore
import Synchronization
import TestProbes

/// A store of kept speech in memory, outliving the rigs built over it as a file outlives the
/// app, and keeping the store's contract.
final class FakeUnheardStore: UnheardStore, Sendable {
    private struct State {
        var files: [(entry: UnheardEntry, samples: [Float])] = []
        var made = 0
        var failing: UnheardFault?
        var unreadable: Set<String> = []
        var unremovable: UnheardFault?
    }

    private let state = Mutex(State())

    /// Every speech kept now, oldest first.
    var kept: [UnheardSpeech] {
        state.withLock { $0.files.map { UnheardSpeech(said: $0.entry.said, vocabulary: $0.entry.vocabulary, samples: $0.samples) } }
    }

    var ids: [String] { state.withLock { $0.files.map(\.entry.id) } }

    /// What every keep throws, when set.
    func fail(keeping fault: UnheardFault?) { state.withLock { $0.failing = fault } }
    /// What every removal throws, when set; the file stays.
    func fail(removing fault: UnheardFault?) { state.withLock { $0.unremovable = fault } }
    /// A file whose samples cannot be read.
    func makeUnreadable(_ id: String) { state.withLock { _ = $0.unreadable.insert(id) } }

    func entries() -> UnheardRead {
        UnheardRead(entries: state.withLock { $0.files.map(\.entry) })
    }

    func keep(_ speech: UnheardSpeech) throws(UnheardFault) -> UnheardEntry {
        try state.withLock { state throws(UnheardFault) in
            if let failing = state.failing { throw failing }
            state.made += 1
            let entry = UnheardEntry(id: "fake-\(state.made)", said: speech.said, seconds: speech.seconds, vocabulary: speech.vocabulary)
            state.files.append((entry, speech.samples))
            return entry
        }
    }

    func samples(of entry: UnheardEntry) throws(UnheardFault) -> [Float] {
        try state.withLock { state throws(UnheardFault) in
            if state.unreadable.contains(entry.id) { throw UnheardFault("the file is unreadable") }
            guard let file = state.files.first(where: { $0.entry == entry }) else { throw UnheardFault("no such file") }
            return file.samples
        }
    }

    func remove(_ entry: UnheardEntry) throws(UnheardFault) {
        try state.withLock { state throws(UnheardFault) in
            if let unremovable = state.unremovable { throw unremovable }
            state.files.removeAll { $0.entry == entry }
        }
    }
}

/// An engine that, like `WhisperKitTranscriber`, runs what it hears through `EngineTurns` as its
/// caller, so a test of what waits for a press and what a press cancels runs the real turn rules
/// and not an engine that ignores them. `served` is the same engine for a served caller.
///
/// The audio is read whole, then decoded as one turn: a pass inside `decode` waits on `inside`
/// when a test sets one, which is how a test holds a decode in flight.
struct TurnedTranscriber: Transcriber {
    /// What it was asked to hear: the samples and the vocabulary they were said under.
    final class Heard: Sendable {
        private let heard = Mutex<[(samples: [Float], vocabulary: Vocabulary)]>([])
        var all: [(samples: [Float], vocabulary: Vocabulary)] { heard.withLock { $0 } }
        fileprivate func add(_ samples: [Float], _ vocabulary: Vocabulary) { heard.withLock { $0.append((samples, vocabulary)) } }
    }

    let turns: EngineTurns
    let heard = Heard()
    let inside: Gate?
    let answer: @Sendable ([Float]) async throws(TranscriptionFailure) -> Transcript
    private var caller: EngineTurns.Caller = .dictation

    init(turns: EngineTurns, inside: Gate? = nil, _ answer: @escaping @Sendable ([Float]) async throws(TranscriptionFailure) -> Transcript) {
        self.turns = turns
        self.inside = inside
        self.answer = answer
    }

    var served: TurnedTranscriber {
        var served = self
        served.caller = .served
        return served
    }

    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        var heardSoFar: [Float] = []
        for await clip in audio { heardSoFar += clip.samples }
        let samples = heardSoFar
        heard.add(samples, vocabulary)
        let answer = answer
        let inside = inside
        let transcript = try await turns.decode(as: caller) { () async throws(TranscriptionFailure) in
            await inside?.wait()
            // A pass a hold cancelled fails, as the real engine's does, and is run again.
            if Task.isCancelled { throw .cancelled }
            return try await answer(samples)
        }
        return Transcription(transcript: transcript, quiet: .none)
    }
}
