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
    /// When the session last saw a key typed, which every reading the input method sends
    /// carries: as the machine came up, until the test types one.
    private var typed = HostTime(uptime: .zero)

    init(listeningFor mode: Mode) {
        detector = HotkeyDetector(modes: try! Modes([mode]), tapThreshold: .milliseconds(250))
    }

    /// The input method telling the app that `modifiers` are held, `ms` into the run.
    mutating func holding(_ modifiers: Set<Modifier>, at ms: Int64) -> [HotkeyDetector.Transition] {
        let reading = HeldModifiers(flags: modifiers.reduce(0) { $0 | $1.mask }, uptimeNanoseconds: nanoseconds(at(ms)),
                                    typedUptimeNanoseconds: nanoseconds(typed))
        return heard(told.take(reading.held, at: reading.changed, lastTyped: reading.lastTyped))
    }

    /// The app reading the session's modifier keys itself, `ms` into the run, the session's
    /// last change at `changed`: long before the read, unless the test says.
    mutating func session(_ modifiers: Set<Modifier>, at ms: Int64, changed: Int64? = nil) -> [HotkeyDetector.Transition] {
        heard(told.confirm(session: modifiers, changed: at(changed ?? ms - 1000), at: at(ms)))
    }

    /// A key that is not a modifier typed `ms` into the run, which the input method is
    /// never handed and the session records.
    mutating func typed(at ms: Int64) {
        typed = at(ms)
    }

    /// Each state in turn, and every press they made.
    mutating func told(_ states: [(Set<Modifier>, Int64)]) -> [HotkeyDetector.Transition] {
        states.flatMap { holding($0.0, at: $0.1) }
    }

    private mutating func heard(_ moves: [KeyEvent]) -> [HotkeyDetector.Transition] {
        moves.compactMap { detector.handle($0) }
    }
}

/// `ms` into a run that starts a minute after the machine came up, so a reading can be dated
/// before it.
private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .seconds(60) + .milliseconds(ms)) }

private func nanoseconds(_ moment: HostTime) -> UInt64 {
    let (seconds, attoseconds) = moment.uptime.components
    return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
}

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
        let released = HeldModifiers(flags: 0, uptimeNanoseconds: pressedAt + 10_000_000, typedUptimeNanoseconds: nil)
        let installed = InputMethodModifiers.Installed<Void>(told: ToldModifiers(held: []), hearing: DispatchQueue(label: #function),
                                                             session: { released })
        installed.open = ((), { heard.yield($0) })
        installed.heard(HeldModifiers(flags: Modifier.rightOption.mask, uptimeNanoseconds: pressedAt, typedUptimeNanoseconds: 0))
        var pressAndRelease: [KeyEvent] = []
        for await move in moves.prefix(2) { pressAndRelease.append(move) }
        installed.open = nil
        #expect(pressAndRelease.map(\.key) == [.rightOption, .rightOption])
        #expect(pressAndRelease.map(\.direction) == [.down, .up])
        #expect(pressAndRelease[1].time - pressAndRelease[0].time >= .milliseconds(200))
        // A threshold under the interval, so the release read from the session is a hold.
        var detector = HotkeyDetector(modes: Config.default.modes, tapThreshold: .milliseconds(100))
        #expect(pressAndRelease.compactMap { detector.handle($0) }
            == [.began(.dictation, at: pressed), .ended(.released(.hold, at: pressAndRelease[1].time))])
    }

    /// A cursor arriving is passed on while the feed is open, and not once it has stopped.
    @MainActor @Test func aCursorArrivingIsPassedOnOnlyWhileTheFeedIsOpen() {
        let installed = InputMethodModifiers.Installed<Void>(told: ToldModifiers(held: []), hearing: DispatchQueue(label: #function),
                                                             session: { HeldModifiers(flags: 0, uptimeNanoseconds: 0, typedUptimeNanoseconds: nil) })
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

    /// Right Option let go of with A typed under it, just before the app reads the session:
    /// the release is left for the input method, whose word carries the A, and the app's
    /// reading lets go of it only once the input method has had `telling` to tell it.
    @Test func aReleaseYoungerThanTellingIsTheInputMethodsToTell() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        told.typed(at: 40)
        #expect(told.session([], at: 212, changed: 210).isEmpty)
        #expect(told.holding([], at: 210) == [.ended(.usedAsModifier)])
    }

    /// The input method's word lost, the next reading lets go of the release.
    @Test func aReleaseTheInputMethodNeverToldIsLetGoOfOnceTellingHasPassed() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        #expect(told.session([], at: 612, changed: 610).isEmpty)
        #expect(told.session([], at: 812, changed: 610) == [.ended(.released(.hold, at: at(812)))])
    }

    /// A hold let go of where the input method is told nothing, with keys typed under it and
    /// after: the app's own reading cannot say which came before the release, so the press is
    /// told by its length, and the hold is the dictation it was.
    @Test func aReleaseOnlyTheSessionSawIsToldByItsLength() {
        var told = Told(listeningFor: oneKey)
        #expect(told.holding([.rightOption], at: 0) == [.began(oneKey, at: at(0))])
        told.typed(at: 40)
        #expect(told.session([], at: 8_200) == [.ended(.released(.hold, at: at(8_200)))])
    }
}
