import Dispatch
import Insertion
@testable import LowTalkerCore
import Testing

/// The input method's hearing, held through the press detection it feeds: a stream of the
/// modifier keys held, as the input method tells them, becomes presses.
///
/// Driven by states rather than by keys, because states are what cross from the input
/// method, told as often as the app it was in hands them over. [LAW:behavior-not-structure]
private struct Told {
    var detector: HotkeyDetector
    private var told = ToldModifiers(held: [])
    /// When the session last saw a key typed, which every reading carries. Long before the
    /// run starts until the test types one.
    private var lastTyped = at(-60_000)

    init(listeningFor mode: Mode) {
        detector = HotkeyDetector(modes: try! Modes([mode]), tapThreshold: .milliseconds(250))
    }

    /// The input method telling the app that `modifiers` are held, `ms` into the run.
    mutating func holding(_ modifiers: Set<Modifier>, at ms: Int64) -> [HotkeyDetector.Transition] {
        heard(told.take(modifiers, at: at(ms), lastTyped: lastTyped))
    }

    /// The app reading the session's modifier keys itself, `ms` into the run.
    mutating func session(_ modifiers: Set<Modifier>, at ms: Int64) -> [HotkeyDetector.Transition] {
        heard(told.confirm(session: modifiers, at: at(ms), lastTyped: lastTyped))
    }

    /// A key that is not a modifier typed `ms` into the run, which the input method is
    /// never handed and the session records.
    mutating func typed(at ms: Int64) {
        lastTyped = at(ms)
    }

    /// Each state in turn, and every press they made.
    mutating func told(_ states: [(Set<Modifier>, Int64)]) -> [HotkeyDetector.Transition] {
        states.flatMap { holding($0.0, at: $0.1) }
    }

    private mutating func heard(_ moves: [KeyEvent]) -> [HotkeyDetector.Transition] {
        moves.compactMap { detector.handle($0) }
    }
}

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

private let oneKey = Mode(name: "dictation", chord: KeyChord(modifiers: .rightOption))
private let twoKeys = Mode(name: "notes", chord: KeyChord(modifiers: .rightOption, .rightCommand))

@Suite struct InputMethodModifiersTests {
    @Test func aHoldBeginsAtThePressAndEndsAtTheRelease() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([], 600)]) == [.began(oneKey, at: at(0)), .ended(.released(.hold, at: at(600)))])
    }

    @Test func aTapLatchesUntilTheNextPress() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([], 100)]) == [.began(oneKey, at: at(0))])
        #expect(told.told([([.rightOption], 2000), ([], 2100)]) == [.ended(.released(.tap, at: at(2000)))])
    }

    /// VS Code hands the input method every change twice, measured on studious,
    /// 2026-09-27, and a tap told twice is still one tap: the second telling of a state
    /// already held changes nothing, where a second key-down would have ended the latch and
    /// begun a new press on the spot.
    @Test func aStateToldTwiceIsToldOnce() {
        var once = Told(listeningFor: oneKey)
        var twice = Told(listeningFor: oneKey)
        let states: [(Set<Modifier>, Int64)] = [([.rightOption], 0), ([], 100), ([.rightOption], 2000), ([], 2100)]
        #expect(twice.told(states.flatMap { [$0, ($0.0, $0.1 + 3)] }) == once.told(states))
    }

    /// Right Option pressed with Shift already down is another chord, and passes by.
    @Test func anotherModifierHeldFirstMakesItAnotherChord() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.leftShift], 0), ([.leftShift, .rightOption], 50), ([.rightOption], 100), ([], 700)]).isEmpty)
    }

    /// Shift added and let go during a hold changes nothing: the press is the chord's.
    @Test func anotherModifierDuringAHoldChangesNothing() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([.rightOption, .leftShift], 200), ([.rightOption], 300), ([], 600)])
            == [.began(oneKey, at: at(0)), .ended(.released(.hold, at: at(600)))])
    }

    /// Right Command then Right Option is the chord of both, and a listener for Right
    /// Option alone hears nothing of it.
    @Test func aChordHeldOnTopOfAnotherKeyIsNotTheChordOfOneKey() {
        var hearingOneKey = Told(listeningFor: oneKey)
        var hearingTwoKeys = Told(listeningFor: twoKeys)
        let states: [(Set<Modifier>, Int64)] = [([.rightCommand], 0), ([.rightCommand, .rightOption], 50), ([], 700)]
        #expect(hearingOneKey.told(states).isEmpty)
        #expect(hearingTwoKeys.told(states) == [.began(twoKeys, at: at(50)), .ended(.released(.hold, at: at(700)))])
    }

    /// Both keys arriving in one state - pressed inside the moment the input method took to
    /// read it - make the press of the chord of both and not of the chord one of them makes
    /// alone, since they were never seen held apart.
    @Test func twoKeysDownInOneStateAreTheChordTheyMakeTogether() {
        var hearingOneKey = Told(listeningFor: oneKey)
        var hearingTwoKeys = Told(listeningFor: twoKeys)
        let states: [(Set<Modifier>, Int64)] = [([.rightCommand, .rightOption], 0), ([], 700)]
        #expect(hearingOneKey.told(states).isEmpty)
        #expect(hearingTwoKeys.told(states) == [.began(twoKeys, at: at(0)), .ended(.released(.hold, at: at(700)))])
    }

    /// A release the input method was never handed - focus moved to where it hears nothing
    /// - is heard in the next state it is told, which no longer holds the key, rather than
    /// leaving the microphone open until the chord is pressed again.
    @Test func aReleaseThatWasNotToldIsHeardInTheNextState() {
        var told = Told(listeningFor: oneKey)
        #expect(told.told([([.rightOption], 0), ([.leftShift], 900)])
            == [.began(oneKey, at: at(0)), .ended(.released(.hold, at: at(900)))])
    }

    /// A release the input method is never told at all - let go over the Desktop, or its
    /// message dropped on a full port - is heard when the app reads the session, not left to
    /// hold the microphone open.
    @Test func aReleaseTheSessionNoLongerHoldsIsHeard() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        #expect(told.session([], at: 800) == [.ended(.released(.hold, at: at(800)))])
    }

    /// The session only confirms: a key down there that the input method never told is not
    /// a press, since the input method is what hears presses.
    @Test func theSessionCannotPress() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.leftShift], at: 0).isEmpty)
        #expect(told.session([.leftShift, .rightOption], at: 200).isEmpty)
        #expect(told.holding([], at: 300).isEmpty)
    }

    /// The input method's message about a hold, arriving after the session was read letting
    /// go of it, is older than that release and does not press the key again.
    @Test func aStateOlderThanTheSessionsReleaseDoesNotPressItAgain() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        #expect(told.session([], at: 800) == [.ended(.released(.hold, at: at(800)))])
        #expect(told.holding([.rightOption], at: 700).isEmpty)
        #expect(told.holding([.rightOption], at: 2000) == [.began(oneKey, at: at(2000))])
    }

    /// Shift let go and Right Option pressed inside one of the app's session reads: the read
    /// lets go of Shift before the input method's messages arrive, and the press they carry,
    /// stamped before the read, is still heard.
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

    /// A key held past `InputMethodModifiers.confirming` is looked for in the session, on
    /// the port's queue, and the release the input method never told is heard from it, no
    /// sooner than one interval after the press.
    @MainActor @Test(.timeLimit(.minutes(1)))
    func aHoldOutlastingTheConfirmingIntervalIsReadFromTheSession() async {
        let (moves, heard) = AsyncStream<KeyEvent>.makeStream()
        let pressedAt = DispatchTime.now().uptimeNanoseconds
        let pressed = HostTime(uptime: .nanoseconds(pressedAt))
        let typed = pressed + .milliseconds(40)
        let installed = InputMethodModifiers.Installed<Void>(told: ToldModifiers(held: []), hearing: DispatchQueue(label: #function),
                                                             session: { [] }, lastTyped: { typed })
        installed.open = ((), { heard.yield($0) })
        installed.heard(HeldModifiers(flags: Modifier.rightOption.mask, uptimeNanoseconds: pressedAt), lastTyped: pressed + .seconds(-60))
        var pressAndRelease: [KeyEvent] = []
        for await move in moves.prefix(2) { pressAndRelease.append(move) }
        installed.open = nil
        #expect(pressAndRelease.map(\.key) == [.rightOption, .rightOption])
        #expect(pressAndRelease.map(\.direction) == [.down, .up])
        #expect(pressAndRelease[1].time - pressAndRelease[0].time >= .milliseconds(200))
        // The session's reading says when a key was last typed too, so a release only the
        // session saw still tells a chord used as a modifier from one pressed alone.
        var detector = HotkeyDetector(modes: Config.default.modes, tapThreshold: Hotkey.defaultTapThreshold)
        #expect(pressAndRelease.compactMap { detector.handle($0) } == [.began(.dictation, at: pressed), .ended(.usedAsModifier)])
    }

    /// A cursor arriving is passed on while the feed is open, and not once it has stopped.
    @MainActor @Test func aCursorArrivingIsPassedOnOnlyWhileTheFeedIsOpen() {
        let installed = InputMethodModifiers.Installed<Void>(told: ToldModifiers(held: []), hearing: DispatchQueue(label: #function),
                                                             session: { [] }, lastTyped: { at(0) })
        var arrivals = 0
        installed.open = ((), { _ in })
        installed.heard(cursorArrivedTo: { arrivals += 1 })
        installed.open = nil
        installed.heard(cursorArrivedTo: { arrivals += 1 })
        #expect(arrivals == 1)
    }

    @Test func aStateThatChangedNothingIsNoKeys() {
        #expect(KeyEvent.moves(from: [.rightOption], to: [.rightOption], at: at(0), lastTyped: at(0)).isEmpty)
    }

    /// Right Option down, A typed, Right Option up, inside 150 ms: the input method is told
    /// only the two modifier states, and the session's record of the A ends the press.
    @Test func aKeyTypedUnderTheChordEndsThePressAtTheRelease() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        told.typed(at: 40)
        #expect(told.holding([], at: 110) == [.ended(.usedAsModifier)])
        #expect(told.detector.phase == .idle)
    }
}
