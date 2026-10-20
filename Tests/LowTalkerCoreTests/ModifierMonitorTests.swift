import Carbon.HIToolbox
import Dispatch
@testable import LowTalkerCore
import Testing

/// The hotkey's hearing, held through the press detection it feeds: a stream of the modifier
/// keys held, as each change's event tells them, becomes presses.
///
/// Driven by states rather than by keys, because a state is what each event carries.
/// [LAW:behavior-not-structure]
private struct Told {
    var detector: HotkeyDetector
    private var told = ToldModifiers(held: [])
    /// When the session last saw a key typed, which every change's reading carries: as the
    /// machine came up, until the test types one.
    private var typed = HostTime(uptime: .zero)

    init(listeningFor mode: Mode) {
        detector = HotkeyDetector(modes: try! Modes([mode]), tapThreshold: .milliseconds(250))
    }

    /// An event telling the app that `modifiers` are held, `ms` into the run.
    mutating func holding(_ modifiers: Set<Modifier>, at ms: Int64) -> [HotkeyDetector.Transition] {
        heard(told.take(modifiers, at: at(ms), lastTyped: typed))
    }

    /// The app reading the session's modifier keys itself, `ms` into the run, the session's
    /// last change at `changed`: long before the read, unless the test says.
    mutating func session(_ modifiers: Set<Modifier>, at ms: Int64, changed: Int64? = nil) -> [HotkeyDetector.Transition] {
        heard(told.confirm(session: modifiers, changed: at(changed ?? ms - 1000), at: at(ms)))
    }

    /// A key that is not a modifier typed `ms` into the run, which no monitor here is handed
    /// and the session records.
    mutating func typed(at ms: Int64) {
        typed = at(ms)
    }

    /// Each state in turn, and every press they made.
    mutating func told(_ states: [(Set<Modifier>, Int64)]) -> [HotkeyDetector.Transition] {
        states.flatMap { holding($0.0, at: $0.1) }
    }

    private mutating func heard(_ moves: [KeyEvent]) -> [HotkeyDetector.Transition] {
        moves.flatMap { detector.handle($0) }
    }
}

/// `ms` into a run that starts a minute after the machine came up, so a reading can be dated
/// before it.
private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .seconds(60) + .milliseconds(ms)) }

/// Seconds since the machine came up, `ms` into the run: the unit events are stamped in.
private func seconds(_ ms: Int64) -> TimeInterval { 60 + Double(ms) / 1000 }

private let oneKey = Mode(name: "dictation", chord: KeyChord(modifiers: .rightOption))
private let twoKeys = Mode(name: "notes", chord: KeyChord(modifiers: .rightOption, .rightCommand))
private let fnKey = Mode(name: "globe", chord: KeyChord(modifiers: .function))

/// The event for a change, `ms` into the run, with nothing typed since the machine came up.
private func change(_ flags: UInt64, key: Int, at ms: Int64) -> FlagsChanged {
    FlagsChanged(flags: flags, keyCode: UInt16(key), timestamp: seconds(ms), lastKeyDown: 0)
}

/// The secondary-Fn bit, which the session also sets for the arrow and navigation keys.
private let fnBit: UInt64 = 0x800000

/// The feed as installed, minus the monitors, telling `heard` every key that moves and
/// `noted` every record it makes. Its session reads `session`, which is never consulted
/// unless a test waits on the timer.
@MainActor
private func installed(heard: @escaping @MainActor (KeyEvent) -> Void, noted: @escaping @MainActor (String) -> Void = { _ in },
                       session: @escaping @MainActor () -> SessionModifiers = { SessionModifiers(session: 0, fnKeyDown: false, changedAt: 0) })
    -> ModifierMonitor.Installed {
    let installed = ModifierMonitor.Installed(told: ToldModifiers(held: []), session: session, noted: noted)
    installed.open = heard
    return installed
}

@Suite struct ModifierMonitorTests {
    @Test func aHoldBeginsAtThePressAndEndsAtTheRelease() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([], 600)]) == [.began(oneKey, at: at(0)), .ended(.released(.hold, at: at(600)))])
    }

    @Test func aTapLatchesUntilTheNextPress() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([], 100)]) == [.began(oneKey, at: at(0))])
        #expect(told.told([([.rightOption], 2000), ([], 2100)]) == [.ended(.released(.tap, at: at(2000)))])
    }

    /// A tap told twice is still one tap: the second telling of a state already held changes
    /// nothing, where a second key-down would have ended the latch and begun a new press on
    /// the spot.
    @Test func aStateToldTwiceIsToldOnce() {
        var once = Told(listeningFor: oneKey)
        var twice = Told(listeningFor: oneKey)
        let states: [(Set<Modifier>, Int64)] = [([.rightOption], 0), ([], 100), ([.rightOption], 2000), ([], 2100)]
        #expect(twice.told(states.flatMap { [$0, ($0.0, $0.1 + 3)] }) == once.told(states))
    }

    /// Right Option pressed with Shift already down begins no press, and is told as blocked
    /// until it comes up.
    @Test func anotherModifierHeldFirstBlocksTheChord() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.leftShift], 0), ([.leftShift, .rightOption], 50), ([.rightOption], 100), ([], 700)])
            == [.blocked(oneKey, by: [.leftShift]), .ended(.released(.hold, at: at(700)))])
    }

    /// Shift added and let go during a hold changes nothing: the press is the chord's.
    @Test func anotherModifierDuringAHoldChangesNothing() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([.rightOption, .leftShift], 200), ([.rightOption], 300), ([], 600)])
            == [.began(oneKey, at: at(0)), .ended(.released(.hold, at: at(600)))])
    }

    /// Right Command then Right Option is the chord of both, and a listener for Right
    /// Option alone hears it as that chord blocked.
    @Test func aChordHeldOnTopOfAnotherKeyIsNotTheChordOfOneKey() {
        var hearingOneKey = Told(listeningFor: oneKey)
        var hearingTwoKeys = Told(listeningFor: twoKeys)
        let states: [(Set<Modifier>, Int64)] = [([.rightCommand], 0), ([.rightCommand, .rightOption], 50), ([], 700)]
        #expect(hearingOneKey.told(states) == [.blocked(oneKey, by: [.rightCommand]), .ended(.released(.hold, at: at(700)))])
        #expect(hearingTwoKeys.told(states) == [.began(twoKeys, at: at(50)), .ended(.released(.hold, at: at(700)))])
    }

    /// Both keys arriving in one state - the change between them never heard - make the
    /// press of the chord of both and not of the chord one of them makes alone, since they
    /// were never seen held apart.
    @Test func twoKeysDownInOneStateAreTheChordTheyMakeTogether() {
        var hearingOneKey = Told(listeningFor: oneKey)
        var hearingTwoKeys = Told(listeningFor: twoKeys)
        let states: [(Set<Modifier>, Int64)] = [([.rightCommand, .rightOption], 0), ([], 700)]
        #expect(hearingOneKey.told(states).isEmpty)
        #expect(hearingTwoKeys.told(states) == [.began(twoKeys, at: at(0)), .ended(.released(.hold, at: at(700)))])
    }

    /// A release no event told is heard in the next state an event tells, which no longer
    /// holds the key, rather than leaving the microphone open until the chord is pressed again.
    @Test func aReleaseThatWasNotToldIsHeardInTheNextState() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([.leftShift], 900)])
            == [.began(oneKey, at: at(0)), .ended(.released(.hold, at: at(900)))])
    }

    /// A release no event tells at all - let go during a session switch - is heard when the
    /// app reads the session, not left to hold the microphone open.
    @Test func aReleaseTheSessionNoLongerHoldsIsHeard() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        #expect(told.session([], at: 800) == [.ended(.released(.hold, at: at(800)))])
    }

    /// The session only confirms: a key down there that no event told is not a press, since
    /// the events are what hear presses.
    @Test func theSessionCannotPress() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.leftShift], at: 0).isEmpty)
        #expect(told.session([.leftShift, .rightOption], at: 200).isEmpty)
        #expect(told.holding([], at: 300).isEmpty)
    }

    /// An event about a hold, handled after the session was read letting go of it - the timer
    /// fired ahead of an event already queued - is older than that release and does not press
    /// the key again.
    @Test func aStateOlderThanTheSessionsReleaseDoesNotPressItAgain() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        #expect(told.session([], at: 800) == [.ended(.released(.hold, at: at(800)))])
        #expect(told.holding([.rightOption], at: 700).isEmpty)
        #expect(told.holding([.rightOption], at: 2000) == [.began(oneKey, at: at(2000))])
    }

    /// Shift let go and Right Option pressed inside one of the app's session reads: the read
    /// lets go of Shift before the events are handled, and the press they carry, stamped
    /// before the read, is still heard.
    @Test func aPressStampedBeforeTheSessionsReadIsStillHeard() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.leftShift], at: 0).isEmpty)
        #expect(told.session([.rightOption], at: 1002).isEmpty)
        #expect(told.holding([], at: 990).isEmpty)
        #expect(told.holding([.rightOption], at: 1000) == [.began(oneKey, at: at(1000))])
        #expect(told.holding([], at: 1700) == [.ended(.released(.hold, at: at(1700)))])
    }

    /// A chord of two keys completed while a session read let go of nothing in between
    /// still presses: a read that changes nothing marks nothing.
    @Test func aSessionReadThatLetGoOfNothingOvertakesNothing() {
        var told = Told(listeningFor: twoKeys)
        #expect(told.holding([.rightCommand], at: 0).isEmpty)
        #expect(told.session([.rightCommand, .rightOption], at: 1002).isEmpty)
        #expect(told.holding([.rightCommand, .rightOption], at: 1000) == [.began(twoKeys, at: at(1000))])
    }

    /// A key held past `ModifierMonitor.confirming` is looked for in the session, on the main
    /// queue, and the release no event told is heard from it, no sooner than one interval
    /// after the press.
    @MainActor @Test(.timeLimit(.minutes(1)))
    func aHoldOutlastingTheConfirmingIntervalIsReadFromTheSession() async {
        let (moves, heard) = AsyncStream<KeyEvent>.makeStream()
        let pressedAt = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let feed = installed(heard: { heard.yield($0) },
                             session: { SessionModifiers(session: 0, fnKeyDown: false, changedAt: pressedAt + 0.01) })
        feed.heard(FlagsChanged(flags: Modifier.rightOption.mask | 0x100, keyCode: UInt16(kVK_RightOption), timestamp: pressedAt,
                                lastKeyDown: 0))
        var pressAndRelease: [KeyEvent] = []
        for await move in moves.prefix(2) { pressAndRelease.append(move) }
        feed.open = nil
        #expect(pressAndRelease.map(\.key) == [.rightOption, .rightOption])
        #expect(pressAndRelease.map(\.direction) == [.down, .up])
        #expect(pressAndRelease[1].time - pressAndRelease[0].time >= .milliseconds(200))
        // A threshold under the interval, so the release read from the session is a hold.
        var detector = HotkeyDetector(modes: Config.default.modes, tapThreshold: .milliseconds(100))
        #expect(pressAndRelease.flatMap { detector.handle($0) }
            == [.began(.dictation, at: HostTime(seconds: pressedAt)), .ended(.released(.hold, at: pressAndRelease[1].time))])
    }

    /// Fn is what the Fn key's own event says, and every other key's event leaves it as it
    /// was: an arrow held under Right Option sets the secondary-Fn bit on Right Option's event
    /// with Fn up, and Right Option let go while Fn is held carries no bit for it. The Fn
    /// key's own event with Fn already held is its release, though an arrow still down sets
    /// the bit on it.
    @Test func fnIsWhatTheFnKeysOwnEventSays() {
        let fnDown = change(fnBit | 0x100, key: kVK_Function, at: 0)
        #expect(fnDown.held(after: []) == [.function])
        #expect(change(0x100, key: kVK_Function, at: 0).held(after: [.function]) == [])
        #expect(fnDown.held(after: [.function]) == [])
        let rightOptionUnderAnArrow = change(Modifier.rightOption.mask | 0x80100 | fnBit, key: kVK_RightOption, at: 0)
        #expect(rightOptionUnderAnArrow.held(after: []) == [.rightOption])
        #expect(change(0x100, key: kVK_RightOption, at: 0).held(after: [.function, .rightOption]) == [.function])
    }

    /// A Fn tap whose down and up are both handled after the up is still a tap, timed by its
    /// events: neither half asks the session what Fn is doing now.
    @MainActor @Test func aFnTapHandledLateIsStillATap() {
        var detector = HotkeyDetector(modes: try! Modes([fnKey]), tapThreshold: .milliseconds(250))
        var transitions: [HotkeyDetector.Transition] = []
        let feed = installed(heard: { transitions += detector.handle($0) })
        feed.heard(change(fnBit | 0x100, key: kVK_Function, at: 0))
        feed.heard(change(0x100, key: kVK_Function, at: 120))
        feed.open = nil
        #expect(transitions == [.began(fnKey, at: at(0))])
        #expect(detector.phase != .idle)
    }

    /// An arrow held while the chord goes down does not make Right Option a chord of Fn.
    @MainActor @Test func theSecondaryFnBitOnAnotherKeysEventPressesNoFn() {
        var detector = HotkeyDetector(modes: try! Modes([oneKey]), tapThreshold: .milliseconds(250))
        var transitions: [HotkeyDetector.Transition] = []
        let feed = installed(heard: { transitions += detector.handle($0) })
        feed.heard(change(Modifier.rightOption.mask | 0x80100 | fnBit, key: kVK_RightOption, at: 0))
        feed.heard(change(0x100, key: kVK_RightOption, at: 600))
        feed.open = nil
        #expect(transitions == [.began(oneKey, at: at(0)), .ended(.released(.hold, at: at(600)))])
    }

    /// The timer fires ahead of an event already queued: Right Command held, the session read
    /// at 1002 ms showing it still down, then the event stamped 1000 ms adding Right Option.
    /// Every reading is applied on the main actor, and the later read lets go of nothing, so
    /// the chord the earlier event completes is pressed.
    @MainActor @Test func aSecondKeyQueuedBehindASessionReadStillCompletesTheChord() {
        var detector = HotkeyDetector(modes: try! Modes([twoKeys]), tapThreshold: .milliseconds(250))
        var transitions: [HotkeyDetector.Transition] = []
        let feed = installed(heard: { transitions += detector.handle($0) })
        feed.heard(change(Modifier.rightCommand.mask | 0x100100, key: kVK_RightCommand, at: 0))
        feed.confirmed(SessionModifiers(session: Modifier.rightCommand.mask | 0x100100, fnKeyDown: false, changedAt: seconds(0)),
                       at: at(1002))
        feed.heard(change(Modifier.rightCommand.mask | Modifier.rightOption.mask | 0x180100, key: kVK_RightOption, at: 1000))
        feed.open = nil
        #expect(transitions == [.began(twoKeys, at: at(1000))])
    }

    /// [LAW:nothing-unseen] Every change heard is one record: the key, its stamp, its flags,
    /// what was typed before it, and what it moved, nothing included.
    @MainActor @Test func everyChangeHeardIsRecordedWithWhatItMoved() {
        var records: [String] = []
        let feed = installed(heard: { _ in }, noted: { records.append($0) })
        feed.heard(FlagsChanged(flags: 0x80140, keyCode: UInt16(kVK_RightOption), timestamp: 60.5, lastKeyDown: 60.25))
        feed.heard(FlagsChanged(flags: 0x80140, keyCode: UInt16(kVK_RightOption), timestamp: 60.75, lastKeyDown: 61))
        feed.open = nil
        #expect(records == [
            "key 61 moved at 60.5: flags 0x80140, a key typed at 60.25: rightOption down",
            "key 61 moved at 60.75: flags 0x80140, a key typed since: no key moved",
        ])
    }

    /// A key typed counts only before the change, by the event's own stamp: Right Option up
    /// at 7_000.4 with an A at 7_000.2 places the A; a key at 7_000.5 places nothing, since it
    /// hides whatever was typed before it. A session that reports a key before the machine
    /// came up has typed none since.
    @Test func aKeyTypedIsPlacedOnlyBeforeTheChange() {
        #expect(FlagsChanged.typed(lastKeyDown: 7_000.2, before: 7_000.4) == 7_000.2)
        #expect(FlagsChanged.typed(lastKeyDown: 7_000.5, before: 7_000.4) == nil)
        #expect(FlagsChanged.typed(lastKeyDown: -0.5, before: 7_000.4) == 0)
    }

    @Test func aStateThatChangedNothingIsNoKeys() {
        #expect(KeyEvent.moves(from: [.rightOption], to: [.rightOption], at: at(0), lastTyped: at(0)).isEmpty)
    }

    /// Right Option down, A typed, Right Option up, inside 150 ms: the monitors are handed
    /// only the two modifier states, and the session's record of the A ends the press.
    @Test func aKeyTypedUnderTheChordEndsThePressAtTheRelease() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        told.typed(at: 40)
        #expect(told.holding([], at: 110) == [.ended(.usedAsModifier)])
        #expect(told.detector.phase == .idle)
    }

    /// Right Option let go of with A typed under it, just before the app reads the session:
    /// the release is left for its event, whose word carries the A, and the app's reading lets
    /// go of it only once the event has had `telling` to tell it.
    @Test func aReleaseYoungerThanTellingIsItsEventsToTell() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        told.typed(at: 40)
        #expect(told.session([], at: 212, changed: 210).isEmpty)
        #expect(told.holding([], at: 210) == [.ended(.usedAsModifier)])
    }

    /// The event's word lost, the next reading lets go of the release.
    @Test func aReleaseNoEventToldIsLetGoOfOnceTellingHasPassed() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        #expect(told.session([], at: 612, changed: 610).isEmpty)
        #expect(told.session([], at: 812, changed: 610) == [.ended(.released(.hold, at: at(812)))])
    }

    /// A hold let go of where no event tells it, with keys typed under it and after: the
    /// app's own reading cannot say which came before the release, so the press is told by its
    /// length, and the hold is the dictation it was.
    @Test func aReleaseOnlyTheSessionSawIsToldByItsLength() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        told.typed(at: 40)
        #expect(told.session([], at: 8_200) == [.ended(.released(.hold, at: at(8_200)))])
    }
}
