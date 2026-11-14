import GrammaticalNumber
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

    /// The press that said held words, while it is open to tell them from every other word held.
    /// [LAW:types-are-the-program] Its identity is the object's, and a run keeps it, so no later
    /// press is ever taken for it. [LAW:one-source-of-truth] It is the press itself, so whether the
    /// person threw it away is read off the press and kept nowhere else.
    public protocol Owner: AnyObject, Sendable {
        /// Whether the person threw the press away, with Escape or the word box's circle.
        var cancelled: Bool { get }
        /// Whether the press is reported, after which nothing throws it away: the words it held
        /// leave the hold only as the person places or dismisses them.
        var reported: Bool { get }
    }

    /// Words held together, why, and who said them.
    struct Run: Sendable {
        let words: [Transcript.Word]
        let warning: String
        /// Nil for words no press here said: read back from the store, or read from kept speech.
        /// Kept weakly: nothing asks which words a press said once it is reported, and a press is
        /// far more than its identity.
        weak var by: (any Owner)?

        /// [LAW:single-enforcer] The one test of which press said a run.
        func said(by owner: any Owner) -> Bool { by === owner }
    }

    /// Words held, and why the latest of them were.
    ///
    /// [LAW:one-source-of-truth] The hold's one account of which held words a press said, so no
    /// press keeps one of its own, and a press tells its words apart without comparing any.
    public struct Part: Sendable, Equatable {
        /// In the order said.
        let runs: [Run]

        public var words: Transcript { Transcript(words: runs.flatMap(\.words)) }
        public var warning: String { runs[runs.count - 1].warning }

        public init?(words: Transcript, warning: String) {
            self.init(runs: [Run(words: words.words, warning: warning, by: nil)])
        }

        /// [LAW:single-enforcer] The one check that what is held holds words: nothing said is
        /// nothing held.
        init?(runs: [Run]) {
            guard !Transcript(words: runs.flatMap(\.words)).isBlank else { return nil }
            self.runs = runs
        }

        fileprivate init(holding runs: [Run]) {
            self.runs = runs
        }

        /// These words after `earlier`, which were said first, under this part's warning.
        func after(_ earlier: [Run]) -> Part {
            Part(holding: earlier + runs)
        }

        /// How many of the words `owner` said.
        func count(by owner: any Owner) -> Int {
            runs.filter { $0.said(by: owner) }.reduce(0) { $0 + $1.words.count }
        }

        /// What is held without the words `owner` said, each word left under the warning it was
        /// held with, or nothing when those are all.
        func without(_ owner: any Owner) -> Part? {
            Part(runs: runs.filter { !$0.said(by: owner) })
        }

        /// What a part is to everything that compares one, the person shown it and the store
        /// keeping it: its words and its warning. Which press said which is the hold's account.
        public static func == (lhs: Part, rhs: Part) -> Bool {
            lhs.words == rhs.words && lhs.warning == rhs.warning
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
        Transcript(words: allRuns.flatMap(\.words))
    }

    fileprivate var allRuns: [Run] {
        [standing, offered].compactMap { $0?.runs }.flatMap { $0 }
    }

    /// What Copy puts on the clipboard: every word held, those that may have landed first, as a
    /// line shows them. All of them, where the box's face may show only the newest.
    public var clipboardText: String {
        allWords.line
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
        case .unplaced(let unplaced, nil): .unplaced(unplaced.after(earlier.offered?.runs ?? []), unaccounted: earlier.standing)
        case .unplaced(let unplaced, let unaccounted?): .unplaced(unplaced, unaccounted: unaccounted.after(earlier.allRuns))
        case .unaccounted(let unaccounted): .unaccounted(unaccounted.after(earlier.allRuns))
        }
    }

    /// Every word held, in the order said, under the latest warning.
    var whole: Part {
        Part(holding: allRuns)
    }

    /// What is held without the words at no cursor that `owner` said. Words that may have landed
    /// always stand.
    func without(_ owner: any Owner) -> Held? {
        Held(unplaced: offered?.without(owner), unaccounted: standing)
    }

    /// Whether something is still held once every press that can still be thrown away is: words
    /// that may have landed, which no throw touches, or words said by no press an Escape can reach
    /// any more, one reported, one gone, or none at all. [LAW:single-enforcer] `Part(runs:)` says
    /// whether what is left holds words, so a warning that came with none is not counted.
    var outlastsEveryThrow: Bool {
        Held(unplaced: offered.flatMap { Part(runs: $0.runs.filter { $0.by?.reported ?? true }) }, unaccounted: standing) != nil
    }

    /// What is left once an insert carrying the words at no cursor landed.
    var placed: Held? {
        Held(unplaced: nil, unaccounted: standing)
    }

    /// Every word held, as words that may have landed, for the reason `warning` gives.
    func mayHaveLanded(_ warning: String) -> Held {
        .unaccounted(Part(holding: allRuns.map { Run(words: $0.words, warning: warning, by: $0.by) }))
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
    /// The person's dismissals, the latest first, each with what is left of it: its words no
    /// throw or insert has taken since. One that comes to hold nothing leaves, and the one it
    /// replaced is the latest again. An Escape dismisses what is held before it reaches the press
    /// it throws away, a main-queue turn later on the detector's path, so a dismissal may come to
    /// hold nothing that press did not take with it, and then the one before it is still the
    /// person's to bring back. Only the latest is kept by the store: once the app ends, no press
    /// that said its words can be thrown away.
    let dismissals: [Held]

    /// The words the person dismissed last, which one step brings back. A later dismissal
    /// replaces them, until it holds nothing.
    /// [LAW:one-source-of-truth] Derived, so no step restores an earlier dismissal: each changes
    /// the dismissals as it changes the dismissed words, and the earlier shows through.
    public var dismissed: Held? { dismissals.first }

    public init(held: Held? = nil, dismissed: Held? = nil) {
        self.init(held: held, dismissals: [dismissed])
    }

    /// [LAW:single-enforcer] Every state with dismissals is made here, so none is kept that nothing
    /// can bring back: below one that outlasts every throw, as only the latest can be emptied by an
    /// insert carrying it. So the dismissals kept are the latest, those that only presses still on
    /// their way said, and one more.
    fileprivate init(held: Held?, dismissals: [Held?]) {
        let dismissals = dismissals.compactMap { $0 }
        self.held = held
        self.dismissals = dismissals.dropFirst().firstIndex(where: \.outlastsEveryThrow).map { Array(dismissals[...$0]) } ?? dismissals
    }

    fileprivate func with(held: Held?) -> HoldState {
        HoldState(held: held, dismissals: dismissals)
    }

    /// With the latest dismissal changed by `change`, the one an insert on its way carries.
    fileprivate func withDismissed(_ change: (Held) -> Held?) -> HoldState {
        HoldState(held: held, dismissals: [dismissed.flatMap(change)] + dismissals.dropFirst().map(Optional.some))
    }

    /// Words counted, never the words themselves: they are what the person dictated.
    public var description: String {
        let held = held.map { "\(counted($0.allWords.words.count, "word", "words")), \($0.standing?.words.words.count ?? 0) of which may have been typed, \($0.warnings.joined(separator: " "))" } ?? "nothing"
        return "\(held); dismissed: \(dismissed.map { counted($0.allWords.words.count, "word", "words") } ?? "nothing")"
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
/// a dictation's words are never thrown away. The one exception is the person's own Escape, which
/// throws a dictation away on purpose: `forget` lets go of the words it left at no cursor.
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

    /// Where the held words an insert on its way carries are now. The loop makes one insert at
    /// a time, changes nothing else while it is on its way, and brings words back in its turn
    /// behind it, so only a dismissal moves them, taking them with what is held.
    /// [LAW:no-ambient-temporal-coupling] Its answer settles these words wherever they are.
    private enum Carried {
        case held
        case dismissed
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
    /// type them a second time, and the dismissed words as they are brought back.
    private var kept: HoldState {
        switch carried {
        case nil: HoldState(held: held, dismissed: dismissed)
        case .held?: HoldState(held: held?.sent, dismissed: dismissed)
        case .dismissed?: HoldState(held: held, dismissed: dismissed?.sent)
        }
    }

    private func hold(_ held: Held?) {
        move(to: state.with(held: held), carrying: carried)
    }

    /// The person let the held words go, until they bring them back. A click that comes after
    /// the words it was shown for were placed lets nothing go, and leaves the earlier dismissal.
    public func dismiss() {
        guard let held else { return }
        standingGeneration += 1
        let carrying: Carried? = switch carried {
        case .held?: .dismissed
        case .dismissed?, nil: nil
        }
        move(to: HoldState(held: nil, dismissals: [held] + state.dismissals), carrying: carrying)
    }

    /// The person brought back the words they dismissed last, ahead of any held since, since
    /// they were said first. In the loop's turn, so no insert is on its way to settle words
    /// these join.
    func bringBack() {
        guard let dismissed else { return }
        precondition(carried == nil, "dismissed words were brought back while an insert was on its way")
        standingGeneration += 1
        move(to: HoldState(held: held.map { $0.after(dismissed) } ?? dismissed, dismissed: nil), carrying: nil)
    }

    /// What is held that an insert made now carries ahead of its own words.
    func sending() -> Held.Part? {
        move(to: state, carrying: held?.offered.map { _ in .held })
        return held?.offered
    }

    /// What is offered, then `words` under `warning`. A run of no words only carries the warning
    /// the part shows, which the run after it replaces, so none is kept behind another.
    private func offering(_ words: Transcript, warning: String, by owner: (any Held.Owner)?) -> [Held.Run] {
        (held?.offered?.runs ?? []).filter { !$0.words.isEmpty } + [Held.Run(words: words.words, warning: warning, by: owner)]
    }

    /// An insert carrying the held words it was sent with landed, which places those words and
    /// says nothing of words that may have landed before it.
    func landed() {
        let next = switch carried {
        case nil: state
        case .held?: state.with(held: held?.placed)
        case .dismissed?: state.withDismissed(\.placed)
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
        hold(held.map { .unplaced($0.whole) })
        return true
    }

    /// An insert of the held words it was sent with and then `words`, which `owner` said, failed
    /// with `failure`.
    /// What is held is read now, not when the insert was sent, so words the person dismissed
    /// while it was on its way stay dismissed, and words that may have landed still stand.
    /// [LAW:one-source-of-truth] One whose words may have landed covers everything it carried,
    /// after the words that may have landed before it, wherever those carried words are now,
    /// and its warning stands in for theirs, which told the person the same thing.
    ///
    /// The person reads the warning, and the app logs it, so it is the failure's facts, which
    /// its account keeps clear of the words. Says how many of `words` it let go, as `heldBack` does.
    @discardableResult
    func failed(_ words: Transcript, by owner: (any Held.Owner)?, with failure: InsertFailure) -> Int {
        let warning = failure.account.facts
        guard failure.wordsMayHaveLanded else { return heldBack(words, by: owner, warning: warning) }
        let unanswered = Held(unplaced: Held.Part(runs: offering(words, warning: warning, by: owner)), unaccounted: held?.standing)
        let answered = switch carried {
        case .dismissed?: state.withDismissed { $0.mayHaveLanded(warning) }
        case .held?, nil: state
        }
        standingGeneration += 1
        move(to: answered.with(held: unanswered?.mayHaveLanded(warning)), carrying: nil)
        return 0
    }

    /// The person threw `owner` away: its own words that no cursor took are let go, from what is
    /// held and from what the person dismissed, since an Escape throws its dictation away wherever
    /// its words are, and every other word stays, under the warning it was held with. Says how
    /// many it let go.
    ///
    /// Words that may have landed stand and are never touched. Standing words are unchanged, so
    /// `standingGeneration` is too. [LAW:one-source-of-truth] Words an insert on its way carries
    /// are where its answer says: taken back by the press once landed, standing once they may
    /// have, and let go by `heldBack` once handed back.
    func forget(_ owner: any Held.Owner) -> Int {
        let next = switch carried {
        case nil: state.without(owner)
        case .held?: state.without(owner).with(held: held)
        case .dismissed?: HoldState(held: held?.without(owner), dismissals: [dismissed] + state.dismissals.dropFirst().map { $0.without(owner) })
        }
        let forgotten = state.offered(by: owner) - next.offered(by: owner)
        move(to: next, carrying: carried)
        return forgotten
    }

    /// What is held and then `words`, which `owner` said, are at no cursor, for the reason `warning` gives the
    /// person, and words that may have landed still stand: those an insert did not place, and
    /// those a press cut short never offered. Nothing said leaves the hold as it was. An insert
    /// that failed placing nothing is answered here, so the words it carried are at no cursor
    /// wherever they are now.
    ///
    /// A press the person threw away holds none of its words at no cursor: an insert it began
    /// before the throw hands back its words and those it carried, which `forget` left to its
    /// answer, and they are let go with nothing shown. Says how many it let go.
    @discardableResult
    func heldBack(_ words: Transcript, by owner: (any Held.Owner)?, warning: String) -> Int {
        let next = state.with(held: Held(unplaced: Held.Part(runs: offering(words, warning: warning, by: owner)), unaccounted: held?.standing))
        let thrown = owner.flatMap { $0.cancelled ? $0 : nil }
        move(to: thrown.map(next.without) ?? next, carrying: nil)
        return thrown.map(next.offered) ?? 0
    }
}

private extension HoldState {
    /// Without the words at no cursor that `owner` said, held or dismissed.
    func without(_ owner: any Held.Owner) -> HoldState {
        HoldState(held: held?.without(owner), dismissals: dismissals.map { $0.without(owner) })
    }

    /// How many of the words at no cursor, held or dismissed, `owner` said.
    func offered(by owner: any Held.Owner) -> Int {
        ([held] + dismissals).reduce(0) { $0 + ($1?.offered?.count(by: owner) ?? 0) }
    }
}
