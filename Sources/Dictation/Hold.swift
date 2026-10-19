import Insertion
import LowTalkerCore

/// What no cursor took, and what the latest try to place it was told.
///
/// [LAW:types-are-the-program] Two cases because a landing settles one and not the other.
public enum Held: Sendable, Equatable {
    /// Words at no cursor, in the order they were said, which the next insert carries ahead
    /// of its own, beside what an earlier insert whose words may have landed was told, while
    /// that warning stands.
    case unplaced(Transcript, warning: String, unaccounted: String? = nil)
    /// Words handed to an app that may yet take them, or sent with no answer to say what became
    /// of them. They are not offered again, since that is the one way to type them twice, and
    /// no later insert says what became of them, so the warning stands until the person
    /// dismisses it.
    case unaccounted(warning: String)

    /// The words the next insert carries.
    public var words: Transcript {
        switch self {
        case .unplaced(let words, _, _): words
        case .unaccounted: Transcript(words: [])
        }
    }

    /// What the person is told, oldest first.
    public var warnings: [String] {
        switch self {
        case .unplaced(_, let warning, let unaccounted): [unaccounted, warning].compactMap { $0 }
        case .unaccounted(let warning): [warning]
        }
    }

    /// The warning a landing leaves standing.
    var standing: String? {
        switch self {
        case .unplaced(_, _, let unaccounted): unaccounted
        case .unaccounted(let warning): warning
        }
    }

    /// What an end of the process leaves held while an insert carrying the held words is on
    /// its way: words handed to an app that may yet take them, like any insert that may have
    /// landed, and like it standing in for a warning before it.
    var sent: Held {
        switch self {
        case .unplaced(let words, _, _): .unaccounted(warning: "LowTalker ended while inserting \(words.words.count) held words, so they may have been typed")
        case .unaccounted: self
        }
    }
}

/// Where what is held is kept from one run of the app to the next.
///
/// [LAW:one-source-of-truth] Once `write` returns, the store holds the `held` it was given, and
/// once it throws `.lost`, nothing. Only `.stale` leaves a state the app has moved past, and
/// says so: the next launch believes the store, and would offer again words already placed,
/// or handed to an app that may have taken them.
@MainActor
public protocol HeldStore {
    /// What was held when the app last ended, nil when nothing was.
    func read() throws(HeldUnreadable) -> Held?
    func write(_ held: Held?) throws(HeldUnkept)
}

/// What was held when the app last ended could not be read back.
public struct HeldUnreadable: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kept: Equatable, Sendable {
        /// Moved where no write reaches it.
        case movedTo(String)
        /// Left where the next write replaces it, since moving it failed for this reason.
        case notMoved(String)
    }

    public let why: String
    public let kept: Kept

    public init(why: String, kept: Kept) {
        self.why = why
        self.kept = kept
    }

    public var description: String {
        switch kept {
        case .movedTo(let path): "what was held when LowTalker last quit could not be read back (\(why)); it is kept at \(path)"
        case .notMoved(let move): "what was held when LowTalker last quit could not be read back (\(why)) or moved aside (\(move)), so what is held since is saved over it"
        }
    }
}

/// A write of what is held failed. [LAW:types-are-the-program] Two cases, because they carry
/// opposite risks.
public enum HeldUnkept: Error, Equatable, Sendable, CustomStringConvertible {
    /// Nothing is kept, so a quit loses what is held.
    case lost(why: String)
    /// An older state is still kept, so the next launch offers words already placed or let go.
    case stale(why: String)

    public var description: String {
        switch self {
        case .lost(let why): "not saved, so a quit now loses them: \(why)"
        case .stale(let why): "an older hold is still saved, so the next launch offers words already placed or let go: \(why)"
        }
    }
}

/// The words no cursor has taken, kept until one does or the person dismisses them. Brandon,
/// 2026-10-15: a dictation's words are never thrown away.
///
/// [LAW:no-shared-mutable-globals] One for the life of the app, so a loop rebuilt over a new
/// config keeps what the old one held. Written by the loop as it places words and by the
/// person through `dismiss`, and every change is written to `store` as it is made, then told
/// to `showing`, so no end of the process leaves the store behind what was shown.
@MainActor
public final class Hold {
    /// Written even when unchanged, since an insert on its way left the store saying what an
    /// end of the process then would, and what it was answered is what puts the store back.
    public private(set) var held: Held? {
        didSet {
            keep(held)
            if held != oldValue { showing(held) }
        }
    }

    /// What reading the store at launch failed with, for the life of the app. Nothing it held
    /// is offered, since nothing could read it.
    public let unrestored: HeldUnreadable?
    /// What the latest write failed with, nil once one succeeds. Memory stays what is held.
    public private(set) var unkept: HeldUnkept?

    private let store: any HeldStore
    private let failedToKeep: @MainActor (HeldUnkept) -> Void
    private let showing: @MainActor (Held?) -> Void

    /// Holds what `store` kept, and tells `showing` of it as of every later change.
    public init(store: any HeldStore, failedToKeep: @escaping @MainActor (HeldUnkept) -> Void, showing: @escaping @MainActor (Held?) -> Void) {
        self.store = store
        self.failedToKeep = failedToKeep
        self.showing = showing
        do throws(HeldUnreadable) {
            held = try store.read()
            unrestored = nil
        } catch {
            held = nil
            unrestored = error
        }
        showing(held)
    }

    private func keep(_ state: Held?) {
        do throws(HeldUnkept) {
            try store.write(state)
            unkept = nil
        } catch {
            unkept = error
            failedToKeep(error)
        }
    }

    /// The person let the held words go.
    public func dismiss() {
        held = nil
    }

    /// What an insert made now carries: what is held, then `words`. Until it is answered the
    /// store holds what an end of the process would leave, so a launch after a crash mid-insert
    /// does not type the held words a second time.
    func sending(_ words: Transcript) -> Transcript {
        keep(held?.sent)
        return offering(words)
    }

    private func offering(_ words: Transcript) -> Transcript {
        Transcript(words: (held?.words.words ?? []) + words.words)
    }

    /// An insert carrying what was held landed, which says nothing of words unaccounted for.
    func landed() {
        held = held?.standing.map { .unaccounted(warning: $0) }
    }

    /// An insert of what is held and then `words` failed with `failure`. What is held is read
    /// now, not when the insert was offered, so words the person dismissed while it was on its
    /// way stay dismissed, and a warning that stands still stands. [LAW:one-source-of-truth]
    /// One whose words may have landed covers everything it carried, the held words with it,
    /// and stands in for a warning before it, which told the person the same thing.
    ///
    /// The person reads the warning, and the app logs it, so it is the failure's facts, which
    /// its account keeps clear of the words.
    func failed(_ words: Transcript, with failure: InsertFailure) {
        let warning = failure.account.facts
        failure.wordsMayHaveLanded ? (held = .unaccounted(warning: warning)) : heldBack(words, warning: warning)
    }

    /// What is held and then `words` are at no cursor, for the reason `warning` gives the
    /// person, and a warning that stands still stands. [LAW:single-enforcer] Every word held
    /// is held here: those an insert did not place, and those a press cut short never offered.
    /// Nothing said changes nothing, since `.unplaced` holds words.
    func heldBack(_ words: Transcript, warning: String) {
        let unplaced = offering(words)
        guard !unplaced.isBlank else { return }
        held = .unplaced(unplaced, warning: warning, unaccounted: held?.standing)
    }
}
