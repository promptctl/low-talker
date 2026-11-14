import Dictation
import LowTalkerCore

/// The held store's semantics, stated once. Each statement runs one fresh store and says every way
/// it disagreed; nothing, when it agreed. `FakeHeldStore` runs it, and so does `HeldFile` over a
/// directory the test owns. [LAW:one-source-of-truth]
@MainActor
public struct HeldStoreContract {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// What is written, held and dismissed, is what is read back.
        case whatIsWrittenIsReadBack
        /// A store nothing was ever written to holds nothing.
        case aStoreNeverWrittenHoldsNothing
        /// Writing nothing held or dismissed leaves nothing, whatever was kept before.
        case writingNothingKeepsNothing
        /// A record that cannot be read is moved aside: the read throws where it went, and the
        /// store holds nothing from then on.
        case anUnreadableRecordIsSetAside
        /// A write that throws `.lost` leaves nothing kept, not what the store held before it.
        case aLostWriteKeepsNothing

        public var description: String {
            switch self {
            case .whatIsWrittenIsReadBack: "what is written is read back"
            case .aStoreNeverWrittenHoldsNothing: "a store never written holds nothing"
            case .writingNothingKeepsNothing: "writing nothing keeps nothing"
            case .anUnreadableRecordIsSetAside: "an unreadable record is set aside"
            case .aLostWriteKeepsNothing: "a lost write keeps nothing"
            }
        }
    }

    /// One store under test, and what puts it in each condition the statements need.
    public struct Subject {
        public let store: any HeldStore
        /// Makes the record kept unreadable, as a file torn by a crash is.
        public let spoil: @MainActor () throws -> Void
        /// Makes the next write fail without keeping anything.
        public let obstruct: @MainActor () throws -> Void

        public init(store: any HeldStore, spoil: @escaping @MainActor () throws -> Void, obstruct: @escaping @MainActor () throws -> Void) {
            self.store = store
            self.spoil = spoil
            self.obstruct = obstruct
        }
    }

    /// A fresh store, nothing written to it.
    public let subject: @MainActor () throws -> Subject

    public init(subject: @escaping @MainActor () throws -> Subject) {
        self.subject = subject
    }

    static let state = HoldState(
        held: .unplaced(Held.Part(words: Transcript(typed: " held"), warning: "refused")!, unaccounted: Held.Part(words: Transcript(typed: "landed"), warning: "may have landed")!),
        dismissed: .unaccounted(Held.Part(words: Transcript(typed: "dismissed"), warning: "may have landed")!)
    )

    public func disagreements(with statement: Statement) throws -> [String] {
        let subject = try subject()
        let store = subject.store
        switch statement {
        case .whatIsWrittenIsReadBack:
            try store.write(Self.state)
            return Self.reading(store, as: Self.state)
        case .aStoreNeverWrittenHoldsNothing:
            return Self.reading(store, as: HoldState())
        case .writingNothingKeepsNothing:
            try store.write(Self.state)
            try store.write(HoldState())
            return Self.reading(store, as: HoldState())
        case .anUnreadableRecordIsSetAside:
            try store.write(Self.state)
            try subject.spoil()
            do {
                let read = try store.read()
                return ["an unreadable record was read as \(read)"]
            } catch {
                guard case .movedTo = error.kept else { return ["an unreadable record was left in place: \(error)"] }
            }
            return Self.reading(store, as: HoldState())
        case .aLostWriteKeepsNothing:
            try store.write(Self.state)
            try subject.obstruct()
            do {
                try store.write(HoldState(held: .unplaced(Held.Part(words: Transcript(typed: " newer"), warning: "refused")!)))
                return ["an obstructed write did not throw"]
            } catch {
                guard case .lost = error else { return ["an obstructed write threw \(error), not lost"] }
            }
            return Self.reading(store, as: HoldState())
        }
    }

    private static func reading(_ store: any HeldStore, as expected: HoldState) -> [String] {
        do {
            let read = try store.read()
            return read == expected ? [] : ["read \(read) where \(expected) was kept"]
        } catch {
            return ["the read threw \(error)"]
        }
    }
}
