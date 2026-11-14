import Dictation
import Foundation
import Synchronization

/// A store of kept speech in memory, outliving the rigs built over it as a file outlives the
/// app, and keeping `UnheardStoreContract` as `UnheardFiles` does.
public final class FakeUnheardStore: UnheardStore, Sendable {
    private struct State {
        var files: [(entry: UnheardEntry, samples: [Float])] = []
        var made = 0
        var failing: UnheardFault?
        var damaged: Set<String> = []
        var unremovable: UnheardFault?
    }

    private let state = Mutex(State())

    public init() {}

    /// Every speech kept now, oldest said first.
    public var kept: [UnheardSpeech] {
        state.withLock { $0.files.map { UnheardSpeech(said: $0.entry.said, vocabulary: $0.entry.vocabulary, samples: $0.samples) } }
    }

    public var ids: [String] { state.withLock { $0.files.map(\.entry.id) } }

    /// What every keep throws, when set.
    public func fail(keeping fault: UnheardFault?) { state.withLock { $0.failing = fault } }
    /// What every removal throws, when set; the file stays.
    public func fail(removing fault: UnheardFault?) { state.withLock { $0.unremovable = fault } }
    /// A file damaged since it was listed: its samples cannot be read, and the next listing sets
    /// it aside.
    public func damage(_ id: String) { state.withLock { _ = $0.damaged.insert(id) } }

    public func entries() -> UnheardRead {
        state.withLock { state in
            let setAside = state.files.filter { state.damaged.contains($0.entry.id) }.map { "kept speech in \($0.entry.id) could not be read (the file is unreadable); it was set aside" }
            state.files.removeAll { state.damaged.contains($0.entry.id) }
            return UnheardRead(entries: state.files.map(\.entry), setAside: setAside)
        }
    }

    public func keep(_ speech: UnheardSpeech) throws(UnheardFault) -> UnheardEntry {
        try state.withLock { state throws(UnheardFault) in
            if let failing = state.failing { throw failing }
            state.made += 1
            let entry = UnheardEntry(id: "fake-\(state.made)", said: speech.said, seconds: speech.seconds, vocabulary: speech.vocabulary)
            // Listed by when each was said, as the files are named.
            let at = state.files.firstIndex { $0.entry.said > speech.said } ?? state.files.endIndex
            state.files.insert((entry, speech.samples), at: at)
            return entry
        }
    }

    public func samples(of entry: UnheardEntry) throws(UnheardFault) -> [Float] {
        try state.withLock { state throws(UnheardFault) in
            if state.damaged.contains(entry.id) { throw UnheardFault("the file is unreadable") }
            guard let file = state.files.first(where: { $0.entry == entry }) else { throw UnheardFault("no such file") }
            return file.samples
        }
    }

    public func remove(_ entry: UnheardEntry) throws(UnheardFault) {
        try state.withLock { state throws(UnheardFault) in
            if let unremovable = state.unremovable { throw unremovable }
            state.files.removeAll { $0.entry == entry }
        }
    }
}
