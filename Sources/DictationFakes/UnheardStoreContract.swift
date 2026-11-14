import Dictation
import Foundation

/// The store of kept speech's semantics, stated once. Each statement runs one fresh store and says
/// every way it disagreed; nothing, when it agreed. `FakeUnheardStore` runs it, and so does
/// `UnheardFiles` over a directory the test owns. [LAW:one-source-of-truth]
public struct UnheardStoreContract: Sendable {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// What is kept is listed, oldest said first, whatever order it was kept in, with when it
        /// was said, how long it is, and its vocabulary.
        case keptSpeechIsListedOldestFirst
        /// An entry's samples are the samples kept.
        case theSamplesKeptAreReadBack
        /// A removed entry is no longer listed, and removing it again is not a failure.
        case aRemovedEntryIsGone
        /// A file damaged after it was listed cannot be read, and the next listing sets it aside
        /// with a line saying so rather than listing it.
        case aDamagedEntryIsSetAside

        public var description: String {
            switch self {
            case .keptSpeechIsListedOldestFirst: "kept speech is listed oldest first"
            case .theSamplesKeptAreReadBack: "the samples kept are read back"
            case .aRemovedEntryIsGone: "a removed entry is gone"
            case .aDamagedEntryIsSetAside: "a damaged entry is set aside"
            }
        }
    }

    /// One store under test, and what damages one of its entries.
    public struct Subject: Sendable {
        public let store: any UnheardStore
        /// Damages what is kept for an entry, as a disk error after it was listed does.
        public let damage: @Sendable (UnheardEntry) throws -> Void

        public init(store: any UnheardStore, damage: @escaping @Sendable (UnheardEntry) throws -> Void) {
            self.store = store
            self.damage = damage
        }
    }

    /// A fresh store, nothing kept in it.
    public let subject: @Sendable () throws -> Subject

    public init(subject: @escaping @Sendable () throws -> Subject) {
        self.subject = subject
    }

    static let earlier = UnheardSpeech(said: Date(timeIntervalSince1970: 1_000_000), vocabulary: ["Kubernetes"], samples: [0.25, -0.5, 1])
    static let later = UnheardSpeech(said: Date(timeIntervalSince1970: 2_000_000), vocabulary: [], samples: Array(repeating: 0.125, count: 16_000))

    public func disagreements(with statement: Statement) throws -> [String] {
        let subject = try subject()
        let store = subject.store
        switch statement {
        case .keptSpeechIsListedOldestFirst:
            _ = try store.keep(Self.later)
            _ = try store.keep(Self.earlier)
            let read = store.entries()
            let listed = read.entries.map { UnheardSpeech(said: $0.said, vocabulary: $0.vocabulary, samples: []) }
            let expected = [Self.earlier, Self.later].map { UnheardSpeech(said: $0.said, vocabulary: $0.vocabulary, samples: []) }
            return (listed == expected ? [] : ["listed \(listed) where \(expected) were kept"])
                + (read.entries.map(\.seconds) == [Self.earlier.seconds, Self.later.seconds] ? [] : ["listed lengths \(read.entries.map(\.seconds))"])
                + read.setAside.map { "set aside: \($0)" }
        case .theSamplesKeptAreReadBack:
            let entry = try store.keep(Self.later)
            let samples = try store.samples(of: entry)
            return samples == Self.later.samples ? [] : ["read \(samples.count) samples back where \(Self.later.samples.count) were kept"]
        case .aRemovedEntryIsGone:
            let entry = try store.keep(Self.earlier)
            let other = try store.keep(Self.later)
            try store.remove(entry)
            try store.remove(entry)
            let listed = store.entries().entries
            return listed.map(\.id) == [other.id] ? [] : ["listed \(listed.map(\.id)) after removing \(entry.id)"]
        case .aDamagedEntryIsSetAside:
            let entry = try store.keep(Self.earlier)
            let other = try store.keep(Self.later)
            _ = store.entries()
            try subject.damage(entry)
            var disagreements: [String] = []
            do {
                let samples = try store.samples(of: entry)
                disagreements.append("a damaged entry read back \(samples.count) samples")
            } catch {}
            let read = store.entries()
            if read.entries.map(\.id) != [other.id] { disagreements.append("listed \(read.entries.map(\.id)) after \(entry.id) was damaged") }
            if read.setAside.count != 1 { disagreements.append("set aside \(read.setAside) after one entry was damaged") }
            return disagreements
        }
    }
}
