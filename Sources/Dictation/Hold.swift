import Insertion
import LowTalkerCore

/// What no cursor took, and why the latest of it was held.
///
/// [LAW:types-are-the-program] Two cases because a landing settles one and not the other.
public enum Held: Sendable, Equatable {
    /// Words at no cursor, in the order they were said, which the next insert carries ahead
    /// of its own, beside words an earlier insert may have landed, while those stand.
    case unplaced(Part, unaccounted: Part? = nil)
    /// Words handed to an app that may yet take them, or sent with no answer to say what became
    /// of them. No insert carries them unless the person asks, since that is the one way to
    /// type them twice, and no later insert says what became of them, so they stand until the
    /// person places or dismisses them.
    case unaccounted(Part)

    /// Words held, and why the latest of them were.
    public struct Part: Sendable, Equatable {
        public let words: Transcript
        public let warning: String

        /// [LAW:single-enforcer] The one check that what is held holds words: nothing said is
        /// nothing held.
        public init?(words: Transcript, warning: String) {
            guard !words.isBlank else { return nil }
            self.words = words
            self.warning = warning
        }

        fileprivate init(holding words: Transcript, warning: String) {
            self.words = words
            self.warning = warning
        }

        /// These words after `earlier`, which were said first, under this part's warning.
        func after(_ earlier: Transcript) -> Part {
            Part(holding: Transcript(words: earlier.words + words.words), warning: warning)
        }
    }

    /// [LAW:single-enforcer] Every held state the hold moves to is made here, so neither part
    /// can be held empty, and a hold of neither is nothing held.
    init?(unplaced: Part?, unaccounted: Part?) {
        switch (unplaced, unaccounted) {
        case let (unplaced?, unaccounted): self = .unplaced(unplaced, unaccounted: unaccounted)
        case let (nil, unaccounted?): self = .unaccounted(unaccounted)
        case (nil, nil): return nil
        }
    }

    /// The words a cursor is offered.
    public var offered: Part? {
        switch self {
        case .unplaced(let unplaced, _): unplaced
        case .unaccounted: nil
        }
    }

    /// The words that may have landed, which a landing leaves standing.
    public var standing: Part? {
        switch self {
        case .unplaced(_, let unaccounted): unaccounted
        case .unaccounted(let unaccounted): unaccounted
        }
    }

    /// The words the next insert carries.
    public var words: Transcript {
        offered?.words ?? Transcript(words: [])
    }

    /// Every word held, in the order said: those that may have landed came first, since an
    /// insert that may have landed took every word held before it.
    public var allWords: Transcript {
        Transcript(words: [standing, offered].compactMap { $0?.words.words }.flatMap { $0 })
    }

    /// What the person is told, oldest first.
    public var warnings: [String] {
        [standing, offered].compactMap { $0?.warning }
    }

    /// The part held last.
    var latest: Part {
        switch self {
        case .unplaced(let unplaced, _): unplaced
        case .unaccounted(let unaccounted): unaccounted
        }
    }

    /// What is held now, after `earlier`, which was said first. [LAW:one-source-of-truth] The
    /// order `failed` keeps: words that may have landed come first, so words that may have landed
    /// here take every word said before them, and words at no cursor here follow the earlier
    /// ones, under the latest warning.
    func after(_ earlier: Held) -> Held {
        switch self {
        case .unplaced(let unplaced, nil): .unplaced(unplaced.after(earlier.words), unaccounted: earlier.standing)
        case .unplaced(let unplaced, let unaccounted?): .unplaced(unplaced, unaccounted: unaccounted.after(earlier.allWords))
        case .unaccounted(let unaccounted): .unaccounted(unaccounted.after(earlier.allWords))
        }
    }

    /// What is left once an insert carrying `carried` landed. The words at no cursor end with
    /// them, since words brought back while it was on its way go ahead of them.
    func placing(_ carried: Part) -> Held? {
        guard case .unplaced(let unplaced, let unaccounted) = self, unplaced.words.words.suffix(carried.words.words.count).elementsEqual(carried.words.words) else {
            preconditionFailure("the words an insert carried are not the last of the words at no cursor")
        }
        let rest = Transcript(words: Array(unplaced.words.words.dropLast(carried.words.words.count)))
        return Held(unplaced: Part(words: rest, warning: unplaced.warning), unaccounted: unaccounted)
    }

    /// Every word held, as words that may have landed, for the reason `warning` gives.
    func mayHaveLanded(_ warning: String) -> Held {
        .unaccounted(Part(holding: allWords, warning: warning))
    }

    /// What an end of the process leaves held while an insert carrying the held words is on
    /// its way: words handed to an app that may yet take them, like any insert that may have
    /// landed, and like it standing in for a warning before it.
    var sent: Held {
        switch self {
        case .unplaced: mayHaveLanded("LowTalker ended while inserting held words, so they may have been typed")
        case .unaccounted: self
        }
    }
}

/// Everything the hold has: the words no cursor took, and the words the person last dismissed.
///
/// [LAW:one-source-of-truth] One value, so the store never keeps the one without the other.
public struct HoldState: Sendable, Equatable, CustomStringConvertible {
    public let held: Held?
    /// The words the person dismissed last, which one step brings back. A later dismissal
    /// replaces them.
    public let dismissed: Held?

    public init(held: Held? = nil, dismissed: Held? = nil) {
        self.held = held
        self.dismissed = dismissed
    }

    /// Words counted, never the words themselves: they are what the person dictated.
    public var description: String {
        let held = held.map { "\($0.allWords.words.count) words, \($0.standing?.words.words.count ?? 0) of them may have been typed, \($0.warnings.joined(separator: " "))" } ?? "nothing"
        return "\(held); dismissed: \(dismissed.map { "\($0.allWords.words.count) words" } ?? "nothing")"
    }
}

/// Where what is held is kept from one run of the app to the next.
///
/// [LAW:one-source-of-truth] Once `write` returns, the store holds the state it was given, and
/// once it throws `.lost`, nothing. Only `.stale` leaves a state the app has moved past, and
/// says so: the next launch believes the store, and would offer again words already placed,
/// or handed to an app that may have taken them.
@MainActor
public protocol HeldStore {
    /// What the hold had when the app last ended.
    func read() throws(HeldUnreadable) -> HoldState
    func write(_ state: HoldState) throws(HeldUnkept)
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

/// The words no cursor has taken, kept until one does, and the words the person dismissed last,
/// kept until one step brings them back or a later dismissal replaces them. Brandon, 2026-10-15:
/// a dictation's words are never thrown away.
///
/// [LAW:no-shared-mutable-globals] One for the life of the app, so a loop rebuilt over a new
/// config keeps what the old one held. Written by the loop as it places words and by the
/// person through `dismiss` and `bringBack`, and every change is written to `store` as it is
/// made, then told to `showing`, so no end of the process leaves the store behind what was shown.
@MainActor
public final class Hold {
    public private(set) var state = HoldState()

    public var held: Held? { state.held }
    public var dismissed: Held? { state.dismissed }

    /// The held words an insert on its way carries, and where they are now. The loop makes one
    /// insert at a time and changes nothing else while it is on its way, so only the person moves
    /// them: a dismissal takes them with what is held, and bringing that back returns them.
    /// [LAW:no-ambient-temporal-coupling] Its answer settles these words wherever they are.
    private enum Carried {
        case held(Held.Part)
        case dismissed(Held.Part)
    }

    private var carried: Carried?

    /// Which words that may have landed stand: a new one each time they are set anew, so an ask
    /// can say which it saw, though the same words come back under the same warning.
    public private(set) var standingGeneration = 0

    /// What reading the store at launch failed with, for the life of the app. Nothing it held
    /// is offered, since nothing could read it.
    public let unrestored: HeldUnreadable?
    /// What the latest write failed with, nil once one succeeds. Memory stays what is held.
    public private(set) var unkept: HeldUnkept?

    private let store: any HeldStore
    private let failedToKeep: @MainActor (HeldUnkept) -> Void
    private let showing: @MainActor (HoldState) -> Void

    /// Holds what `store` kept, and tells `showing` of it as of every later change.
    public init(store: any HeldStore, failedToKeep: @escaping @MainActor (HeldUnkept) -> Void, showing: @escaping @MainActor (HoldState) -> Void) {
        self.store = store
        self.failedToKeep = failedToKeep
        self.showing = showing
        do throws(HeldUnreadable) {
            state = try store.read()
            unrestored = nil
        } catch {
            unrestored = error
        }
        showing(state)
    }

    /// [LAW:single-enforcer] Every change passes through here. The store is written even when
    /// the state is unchanged, since the answer to an insert puts back the store its sending
    /// changed.
    private func move(to next: HoldState, carrying: Carried?) {
        let shown = state
        state = next
        carried = carrying
        do throws(HeldUnkept) {
            try store.write(kept)
            unkept = nil
        } catch {
            unkept = error
            failedToKeep(error)
        }
        if state != shown { showing(state) }
    }

    /// What the store keeps: the state, with the words an insert on its way carries kept as an
    /// end of the process then would leave them, so a launch after a crash mid-insert does not
    /// type them a second time.
    private var kept: HoldState {
        switch carried {
        case nil: state
        case .held?: HoldState(held: held?.sent, dismissed: dismissed)
        case .dismissed?: HoldState(held: held, dismissed: dismissed?.sent)
        }
    }

    private func hold(_ held: Held?) {
        move(to: HoldState(held: held, dismissed: dismissed), carrying: carried)
    }

    /// The person let the held words go, until they bring them back. A click that comes after
    /// the words it was shown for were placed lets nothing go, and leaves the earlier dismissal.
    public func dismiss() {
        guard let held else { return }
        standingGeneration += 1
        let carrying: Carried? = switch carried {
        case .held(let words)?: .dismissed(words)
        case .dismissed?, nil: nil
        }
        move(to: HoldState(held: nil, dismissed: held), carrying: carrying)
    }

    /// The person brought back the words they dismissed last, ahead of any held since, since
    /// they were said first.
    func bringBack() {
        guard let dismissed else { return }
        standingGeneration += 1
        let carrying: Carried? = switch carried {
        case .held(let words)?, .dismissed(let words)?: .held(words)
        case nil: nil
        }
        move(to: HoldState(held: held.map { $0.after(dismissed) } ?? dismissed, dismissed: nil), carrying: carrying)
    }

    /// What an insert made now carries: what is held, then `words`.
    func sending(_ words: Transcript) -> Transcript {
        move(to: state, carrying: held?.offered.map(Carried.held))
        return offering(words)
    }

    private func offering(_ words: Transcript) -> Transcript {
        Transcript(words: (held?.words.words ?? []) + words.words)
    }

    /// An insert carrying the held words it was sent with landed, which places those words and
    /// says nothing of words that may have landed before it.
    func landed() {
        let next = switch carried {
        case nil: state
        case .held(let words)?: HoldState(held: held?.placing(words), dismissed: dismissed)
        case .dismissed(let words)?: HoldState(held: held, dismissed: dismissed?.placing(words))
        }
        move(to: next, carrying: nil)
    }

    /// The person asked for every held word at the cursor, saying the words that may have landed
    /// as they saw them, in `generation`, were not typed: those are offered with the rest, under
    /// the latest warning. Only while that generation stands, since an insert whose words may
    /// have landed sets them anew, and of those the person has said nothing. Says whether it
    /// was taken.
    func asked(vouching generation: Int) -> Bool {
        guard generation == standingGeneration else { return false }
        standingGeneration += 1
        hold(held.flatMap { held in Held(unplaced: Held.Part(words: held.allWords, warning: held.latest.warning), unaccounted: nil) })
        return true
    }

    /// An insert of the held words it was sent with and then `words` failed with `failure`.
    /// What is held is read now, not when the insert was sent, so words the person dismissed
    /// while it was on its way stay dismissed, and words that may have landed still stand.
    /// [LAW:one-source-of-truth] One whose words may have landed covers everything it carried,
    /// after the words that may have landed before it, wherever those carried words are now,
    /// and its warning stands in for theirs, which told the person the same thing.
    ///
    /// The person reads the warning, and the app logs it, so it is the failure's facts, which
    /// its account keeps clear of the words.
    func failed(_ words: Transcript, with failure: InsertFailure) {
        let warning = failure.account.facts
        guard failure.wordsMayHaveLanded else { return heldBack(words, warning: warning) }
        let unanswered = Transcript(words: (held?.allWords.words ?? []) + words.words)
        let dismissed = switch carried {
        case .dismissed?: dismissed?.mayHaveLanded(warning)
        case .held?, nil: dismissed
        }
        standingGeneration += 1
        move(to: HoldState(held: Held(unplaced: nil, unaccounted: Held.Part(words: unanswered, warning: warning)), dismissed: dismissed), carrying: nil)
    }

    /// What is held and then `words` are at no cursor, for the reason `warning` gives the
    /// person, and words that may have landed still stand: those an insert did not place, and
    /// those a press cut short never offered. Nothing said leaves the hold as it was. An insert
    /// that failed placing nothing is answered here, so the words it carried are at no cursor
    /// wherever they are now.
    func heldBack(_ words: Transcript, warning: String) {
        move(to: HoldState(held: Held(unplaced: Held.Part(words: offering(words), warning: warning), unaccounted: held?.standing), dismissed: dismissed), carrying: nil)
    }
}
