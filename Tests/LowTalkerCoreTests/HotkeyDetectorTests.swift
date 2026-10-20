import LowTalkerCore
import Testing

private let rightOption = Mode(name: "dictation", chord: KeyChord(modifiers: .rightOption))
private let command = Mode(name: "command", chord: KeyChord(modifiers: .rightOption, .leftShift))
private let rightCommand = Mode(name: "notes", chord: KeyChord(modifiers: .rightCommand))

/// A keyboard the test types on, event by event, at the moments it says.
private struct Keyboard {
    var detector: HotkeyDetector
    /// The modifiers down right now, so each event reports the whole state the way
    /// the input method does.
    private var held: Set<Modifier> = []
    /// When a key was last typed, which every event carries as the session does. Long
    /// before the run starts until the test types one.
    private var lastTyped = at(-60_000)

    init(modes: Modes = modes(rightOption), tapThreshold: Duration = .milliseconds(250)) {
        detector = HotkeyDetector(modes: modes, tapThreshold: tapThreshold)
    }

    mutating func press(_ modifier: Modifier, at ms: Int64) -> HotkeyDetector.Transition? {
        held.insert(modifier)
        return detector.handle(KeyEvent(key: modifier, direction: .down, modifiers: held, time: at(ms), lastTyped: lastTyped))
    }

    mutating func release(_ modifier: Modifier, at ms: Int64) -> HotkeyDetector.Transition? {
        held.remove(modifier)
        return detector.handle(KeyEvent(key: modifier, direction: .up, modifiers: held, time: at(ms), lastTyped: lastTyped))
    }

    /// A key that is not a modifier typed at `ms`, which the detector is never handed and
    /// learns of from the next event.
    mutating func type(at ms: Int64) {
        lastTyped = at(ms)
    }
}

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

private func began(_ mode: Mode, at ms: Int64) -> HotkeyDetector.Transition { .began(mode, at: at(ms)) }
private func ended(_ press: PressKind, at ms: Int64) -> HotkeyDetector.Transition { .ended(.released(press, at: at(ms))) }

/// Modes the test vouches for: listed by hand, none sharing a chord or a name.
private func modes(_ listed: Mode...) -> Modes { try! Modes(listed) }

@Suite struct HotkeyDetectorTests {
    @Test func aPressReleasedAfterTheThresholdIsAHold() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        #expect(keyboard.detector.phase == .held(rightOption.chord, since: at(0)))
        #expect(keyboard.release(.rightOption, at: 400) == ended(.hold, at: 400))
        #expect(keyboard.detector.phase == .idle)
    }

    /// A tap leaves listening on; the next press of the chord ends it, and that press
    /// is consumed whole, however long it lasts.
    @Test func aPressReleasedWithinTheThresholdLatchesUntilTheNextPress() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        #expect(keyboard.release(.rightOption, at: 100) == nil)
        #expect(keyboard.detector.phase == .latched(rightOption.chord))
        #expect(keyboard.press(.rightOption, at: 5000) == ended(.tap, at: 5000))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 6000) == nil)
        #expect(keyboard.detector.phase == .idle)
    }

    @Test func aPressExactlyAtTheThresholdIsAHold() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 10)
        #expect(keyboard.release(.rightOption, at: 260) == ended(.hold, at: 260))
    }

    @Test func theThresholdIsTheDetectorsToSet() {
        var keyboard = Keyboard(tapThreshold: .milliseconds(50))
        _ = keyboard.press(.rightOption, at: 0)
        #expect(keyboard.release(.rightOption, at: 100) == ended(.hold, at: 100))
    }

    /// Modifiers that are not the chord's change nothing, whatever the phase.
    @Test func otherModifiersChangeNothingInEveryPhase() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 20)
        #expect(keyboard.press(.leftOption, at: 50) == nil)
        #expect(keyboard.release(.leftOption, at: 60) == nil)
        #expect(keyboard.detector.phase == .held(rightOption.chord, since: at(20)))
        _ = keyboard.release(.rightOption, at: 70)
        #expect(keyboard.detector.phase == .latched(rightOption.chord))
        #expect(keyboard.press(.leftShift, at: 80) == nil)
        #expect(keyboard.release(.leftShift, at: 90) == nil)
        #expect(keyboard.detector.phase == .latched(rightOption.chord))
    }

    /// Right Option with Command already held is not the chord, so no press begins, but it is
    /// told as blocked at the chord and ended as the chord comes up, so the person learns it
    /// before speaking.
    @Test func theChordWithAnotherModifierHeldIsBlocked() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.leftCommand, at: 0) == nil)
        #expect(keyboard.press(.rightOption, at: 10) == .blocked(rightOption, by: [.leftCommand]))
        #expect(keyboard.detector.phase == .blocked(rightOption.chord, since: at(10)))
        #expect(keyboard.release(.leftCommand, at: 300) == nil)
        #expect(keyboard.release(.rightOption, at: 400) == ended(.hold, at: 400))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.press(.rightOption, at: 1000) == began(rightOption, at: 1000))
    }

    /// A latched tap's chord pressed with Shift held still ends it: the person reached for it
    /// to stop listening.
    @Test func theChordWithAnotherModifierHeldEndsALatchedTap() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 0)
        _ = keyboard.release(.rightOption, at: 50)
        _ = keyboard.press(.leftShift, at: 500)
        #expect(keyboard.press(.rightOption, at: 510) == ended(.tap, at: 510))
        #expect(keyboard.detector.phase == .idle)
    }

    /// Nothing is listening, so a blocked chord let go quickly latches nothing: it ends, and
    /// the next press of the chord alone begins one.
    @Test func aBlockedChordTappedEndsAndLatchesNothing() {
        var keyboard = Keyboard()
        _ = keyboard.press(.leftShift, at: 0)
        _ = keyboard.press(.rightOption, at: 10)
        #expect(keyboard.release(.rightOption, at: 60) == ended(.tap, at: 60))
        #expect(keyboard.detector.phase == .idle)
        _ = keyboard.release(.leftShift, at: 70)
        #expect(keyboard.press(.rightOption, at: 100) == began(rightOption, at: 100))
    }

    /// Shift and Right Option held to type a special character: the blocked chord was the
    /// typed key's modifier, and ends as one.
    @Test func aBlockedChordWithAKeyTypedUnderItEndsAsAModifier() {
        var keyboard = Keyboard()
        _ = keyboard.press(.leftShift, at: 0)
        _ = keyboard.press(.rightOption, at: 10)
        keyboard.type(at: 40)
        #expect(keyboard.release(.rightOption, at: 90) == .ended(.usedAsModifier))
    }

    /// Of the chords the extra keys block, the one with the most keys is the one named.
    @Test func theMostSpecificBlockedChordIsNamed() {
        var keyboard = Keyboard(modes: modes(rightOption, command))
        _ = keyboard.press(.leftShift, at: 0)
        _ = keyboard.press(.function, at: 5)
        #expect(keyboard.press(.rightOption, at: 10) == .blocked(command, by: [.function]))
    }

    /// A blocked chord ends with the hotkey's lapse like any press.
    @Test func aLapseEndsABlockedChord() {
        var keyboard = Keyboard()
        _ = keyboard.press(.leftCommand, at: 0)
        _ = keyboard.press(.rightOption, at: 10)
        #expect(keyboard.detector.lapse() == .ended(.lapsed))
        #expect(keyboard.detector.phase == .idle)
    }

    /// While a blocked chord is down, another chord completing changes nothing.
    @Test func aChordCompletedWhileBlockedIsIgnored() {
        var keyboard = Keyboard(modes: modes(rightOption, rightCommand))
        _ = keyboard.press(.leftShift, at: 0)
        _ = keyboard.press(.rightOption, at: 10)
        _ = keyboard.release(.leftShift, at: 20)
        #expect(keyboard.press(.rightCommand, at: 30) == nil)
        #expect(keyboard.detector.phase == .blocked(rightOption.chord, since: at(10)))
    }

    /// The chord that began the press owns it: adding Shift to a held Right Option
    /// changes nothing, though Right Option with Shift is itself a chord.
    @Test func aChordCompletedOnTopOfAHeldOneIsIgnored() {
        var keyboard = Keyboard(modes: modes(rightOption, command))
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        #expect(keyboard.press(.leftShift, at: 100) == nil)
        #expect(keyboard.detector.phase == .held(rightOption.chord, since: at(0)))
        #expect(keyboard.release(.leftShift, at: 200) == nil)
        #expect(keyboard.release(.rightOption, at: 400) == ended(.hold, at: 400))
    }

    /// Shift first, then Right Option, is the two-key chord, and releasing either ends
    /// the press.
    @Test func theOrderOfKeysPicksTheChord() {
        var keyboard = Keyboard(modes: modes(rightOption, command))
        #expect(keyboard.press(.leftShift, at: 0) == nil)
        #expect(keyboard.press(.rightOption, at: 10) == began(command, at: 10))
        #expect(keyboard.release(.leftShift, at: 400) == ended(.hold, at: 400))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 410) == nil)
    }

    /// The two-key chord released on either key within the threshold latches like any tap.
    @Test func releasingEitherKeyOfAChordWithinTheThresholdLatches() {
        var keyboard = Keyboard(modes: modes(rightOption, command))
        _ = keyboard.press(.leftShift, at: 0)
        #expect(keyboard.press(.rightOption, at: 10) == began(command, at: 10))
        #expect(keyboard.release(.leftShift, at: 100) == nil)
        #expect(keyboard.detector.phase == .latched(command.chord))
        #expect(keyboard.release(.rightOption, at: 110) == nil)
        #expect(keyboard.detector.phase == .latched(command.chord))
    }

    /// A saved config moves the chord mid-hold: the press open under the old chord is
    /// neither dropped nor ended, it ends at that chord's release, and the next press is
    /// heard on the new chord alone.
    @Test func aHoldOpenWhenTheChordMovesEndsAtItsOwnRelease() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        keyboard.detector.listen(for: modes(rightCommand))
        #expect(keyboard.detector.phase == .held(rightOption.chord, since: at(0)))
        #expect(keyboard.release(.rightOption, at: 400) == ended(.hold, at: 400))
        #expect(keyboard.press(.rightOption, at: 500) == nil)
        #expect(keyboard.release(.rightOption, at: 900) == nil)
        #expect(keyboard.press(.rightCommand, at: 1000) == began(rightCommand, at: 1000))
    }

    /// A saved config gives the held chord's mode a vocabulary mid-hold: the press keeps the
    /// mode it began in, so its decode and its record agree on what it expected, and the next
    /// press begins in the mode as saved.
    @Test func aHoldOpenWhenItsModeChangesKeepsTheModeItBeganIn() throws {
        let saved = Mode(name: "dictation", chord: rightOption.chord, vocabulary: Vocabulary([try Vocabulary.Term("Brynleigh")]))
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        keyboard.detector.listen(for: modes(saved))
        #expect(keyboard.release(.rightOption, at: 400) == ended(.hold, at: 400))
        #expect(keyboard.press(.rightOption, at: 1000) == began(saved, at: 1000))
    }

    /// A tap latched under the old chord stays latched, and is ended by the chord that began
    /// it - the one the person tapped to start - or by the chord listened for now, the one
    /// the menu names. Neither leaves the microphone recording with no way to stop it.
    @Test(arguments: [Modifier.rightOption, .rightCommand])
    func aTapLatchedWhenTheChordMovesIsEndedByEitherChord(_ ending: Modifier) {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 0)
        _ = keyboard.release(.rightOption, at: 100)
        keyboard.detector.listen(for: modes(rightCommand))
        #expect(keyboard.detector.phase == .latched(rightOption.chord))
        #expect(keyboard.press(ending, at: 2000) == ended(.tap, at: 2000))
        #expect(keyboard.detector.phase == .idle)
    }

    /// A lapse ends whatever press is open, a hold or a latched tap, and says that is
    /// what ended it.
    @Test func aLapseEndsWhateverPressIsOpen() {
        var keyboard = Keyboard()
        #expect(keyboard.detector.lapse() == nil)
        _ = keyboard.press(.rightOption, at: 0)
        #expect(keyboard.detector.lapse() == .ended(.lapsed))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 10) == nil)
        _ = keyboard.press(.rightOption, at: 100)
        _ = keyboard.release(.rightOption, at: 150)
        #expect(keyboard.detector.lapse() == .ended(.lapsed))
        #expect(keyboard.detector.phase == .idle)
    }

    /// The requirement in one line: what a lapse ends a press with and what a release
    /// ends one with are not equal, so no consumer can read either as the other.
    @Test func aLapseAndAReleaseAreNotTheSameValue() {
        var lapsing = Keyboard()
        _ = lapsing.press(.rightOption, at: 0)
        let lapsed = lapsing.detector.lapse()

        var releasing = Keyboard()
        _ = releasing.press(.rightOption, at: 0)
        let released = releasing.release(.rightOption, at: 400)

        #expect(lapsed == .ended(.lapsed))
        #expect(released == .ended(.released(.hold, at: at(400))))
        #expect(lapsed != released)
    }

    /// While latched, any configured chord ends the listening, not only the one that
    /// began it.
    @Test func anyChordPressEndsALatchedSession() {
        var keyboard = Keyboard(modes: modes(rightOption, command))
        _ = keyboard.press(.rightOption, at: 0)
        _ = keyboard.release(.rightOption, at: 100)
        _ = keyboard.press(.leftShift, at: 1000)
        #expect(keyboard.press(.rightOption, at: 1010) == ended(.tap, at: 1010))
    }

    /// Right Option held to type a special character, quicker than a tap: the chord was the
    /// key's modifier, so it ends there and latches nothing.
    @Test(arguments: [Int64(110), 900])
    func aKeyTypedUnderTheChordEndsThePressAsItComesUp(releasedAt ms: Int64) {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        keyboard.type(at: 40)
        #expect(keyboard.release(.rightOption, at: ms) == .ended(.usedAsModifier))
        #expect(keyboard.detector.phase == .idle)
    }

    /// Only a key typed while the chord was down makes it a modifier: one typed before it
    /// went down leaves a tap.
    @Test(arguments: [Int64(-5), 0])
    func aKeyTypedOutsideTheChordLeavesATap(typedAt ms: Int64) {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 0)
        keyboard.type(at: ms)
        #expect(keyboard.release(.rightOption, at: 100) == nil)
        #expect(keyboard.detector.phase == .latched(rightOption.chord))
    }

    /// A release whose reading cannot say when a key was typed before it, because one typed
    /// after hides it, is told by its length.
    @Test func aReleaseThatCannotSayWhatWasTypedIsToldByItsLength() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 0)
        #expect(keyboard.detector.handle(KeyEvent(key: .rightOption, direction: .up, modifiers: [], time: at(100), lastTyped: nil)) == nil)
        #expect(keyboard.detector.phase == .latched(rightOption.chord))
    }

    /// Typing while a tap is latched is what a latched tap is for, and ends nothing.
    @Test func aKeyTypedWhileLatchedChangesNothing() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 0)
        _ = keyboard.release(.rightOption, at: 100)
        keyboard.type(at: 500)
        #expect(keyboard.press(.rightOption, at: 1000) == ended(.tap, at: 1000))
    }
}
