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

    init(modes: [Mode] = [rightOption], tapThreshold: Duration = .milliseconds(250)) {
        detector = HotkeyDetector(modes: modes, tapThreshold: tapThreshold)
    }

    mutating func press(_ modifier: Modifier, at ms: Int64) -> HotkeyDetector.Transition? {
        held.insert(modifier)
        return detector.handle(KeyEvent(key: modifier, direction: .down, modifiers: held, time: at(ms)))
    }

    mutating func release(_ modifier: Modifier, at ms: Int64) -> HotkeyDetector.Transition? {
        held.remove(modifier)
        return detector.handle(KeyEvent(key: modifier, direction: .up, modifiers: held, time: at(ms)))
    }
}

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

private func began(_ mode: Mode, at ms: Int64) -> HotkeyDetector.Transition { .began(mode, at: at(ms)) }
private func ended(_ mode: Mode, _ press: PressKind, at ms: Int64) -> HotkeyDetector.Transition { .ended(mode, .released(press, at: at(ms))) }

@Suite struct HotkeyDetectorTests {
    @Test func aPressReleasedAfterTheThresholdIsAHold() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        #expect(keyboard.detector.phase == .held(rightOption, since: at(0)))
        #expect(keyboard.release(.rightOption, at: 400) == ended(rightOption, .hold, at: 400))
        #expect(keyboard.detector.phase == .idle)
    }

    /// A tap leaves listening on; the next press of the chord ends it, and that press
    /// is consumed whole, however long it lasts.
    @Test func aPressReleasedWithinTheThresholdLatchesUntilTheNextPress() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        #expect(keyboard.release(.rightOption, at: 100) == nil)
        #expect(keyboard.detector.phase == .latched(rightOption))
        #expect(keyboard.press(.rightOption, at: 5000) == ended(rightOption, .tap, at: 5000))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 6000) == nil)
        #expect(keyboard.detector.phase == .idle)
    }

    @Test func aPressExactlyAtTheThresholdIsAHold() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 10)
        #expect(keyboard.release(.rightOption, at: 260) == ended(rightOption, .hold, at: 260))
    }

    @Test func theThresholdIsTheDetectorsToSet() {
        var keyboard = Keyboard(tapThreshold: .milliseconds(50))
        _ = keyboard.press(.rightOption, at: 0)
        #expect(keyboard.release(.rightOption, at: 100) == ended(rightOption, .hold, at: 100))
    }

    /// Modifiers that are not the chord's change nothing, whatever the phase.
    @Test func otherModifiersChangeNothingInEveryPhase() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 20)
        #expect(keyboard.press(.leftOption, at: 50) == nil)
        #expect(keyboard.release(.leftOption, at: 60) == nil)
        #expect(keyboard.detector.phase == .held(rightOption, since: at(20)))
        _ = keyboard.release(.rightOption, at: 70)
        #expect(keyboard.detector.phase == .latched(rightOption))
        #expect(keyboard.press(.leftShift, at: 80) == nil)
        #expect(keyboard.release(.leftShift, at: 90) == nil)
        #expect(keyboard.detector.phase == .latched(rightOption))
    }

    /// Right Option with Command already held is a different chord, and one that is
    /// not configured.
    @Test func theChordWithAnotherModifierHeldIsNotThePress() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.leftCommand, at: 0) == nil)
        #expect(keyboard.press(.rightOption, at: 10) == nil)
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 400) == nil)
        #expect(keyboard.release(.leftCommand, at: 410) == nil)
    }

    /// The chord that began the press owns it: adding Shift to a held Right Option
    /// changes nothing, though Right Option with Shift is itself a chord.
    @Test func aChordCompletedOnTopOfAHeldOneIsIgnored() {
        var keyboard = Keyboard(modes: [rightOption, command])
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        #expect(keyboard.press(.leftShift, at: 100) == nil)
        #expect(keyboard.detector.phase == .held(rightOption, since: at(0)))
        #expect(keyboard.release(.leftShift, at: 200) == nil)
        #expect(keyboard.release(.rightOption, at: 400) == ended(rightOption, .hold, at: 400))
    }

    /// Shift first, then Right Option, is the two-key chord, and releasing either ends
    /// the press.
    @Test func theOrderOfKeysPicksTheChord() {
        var keyboard = Keyboard(modes: [rightOption, command])
        #expect(keyboard.press(.leftShift, at: 0) == nil)
        #expect(keyboard.press(.rightOption, at: 10) == began(command, at: 10))
        #expect(keyboard.release(.leftShift, at: 400) == ended(command, .hold, at: 400))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 410) == nil)
    }

    /// The two-key chord released on either key within the threshold latches like any tap.
    @Test func releasingEitherKeyOfAChordWithinTheThresholdLatches() {
        var keyboard = Keyboard(modes: [rightOption, command])
        _ = keyboard.press(.leftShift, at: 0)
        #expect(keyboard.press(.rightOption, at: 10) == began(command, at: 10))
        #expect(keyboard.release(.leftShift, at: 100) == nil)
        #expect(keyboard.detector.phase == .latched(command))
        #expect(keyboard.release(.rightOption, at: 110) == nil)
        #expect(keyboard.detector.phase == .latched(command))
    }

    /// A saved config moves the chord mid-hold: the press open under the old chord is
    /// neither dropped nor ended, it ends at that chord's release, and the next press is
    /// heard on the new chord alone.
    @Test func aHoldOpenWhenTheChordMovesEndsAtItsOwnRelease() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption, at: 0))
        keyboard.detector.listen(for: [rightCommand])
        #expect(keyboard.detector.phase == .held(rightOption, since: at(0)))
        #expect(keyboard.release(.rightOption, at: 400) == ended(rightOption, .hold, at: 400))
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
        keyboard.detector.listen(for: [saved])
        #expect(keyboard.release(.rightOption, at: 400) == ended(rightOption, .hold, at: 400))
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
        keyboard.detector.listen(for: [rightCommand])
        #expect(keyboard.detector.phase == .latched(rightOption))
        #expect(keyboard.press(ending, at: 2000) == ended(rightOption, .tap, at: 2000))
        #expect(keyboard.detector.phase == .idle)
    }

    /// A lapse ends whatever press is open, a hold or a latched tap, and says that is
    /// what ended it.
    @Test func aLapseEndsWhateverPressIsOpen() {
        var keyboard = Keyboard()
        #expect(keyboard.detector.lapse() == nil)
        _ = keyboard.press(.rightOption, at: 0)
        #expect(keyboard.detector.lapse() == .ended(rightOption, .lapsed))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 10) == nil)
        _ = keyboard.press(.rightOption, at: 100)
        _ = keyboard.release(.rightOption, at: 150)
        #expect(keyboard.detector.lapse() == .ended(rightOption, .lapsed))
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

        #expect(lapsed == .ended(rightOption, .lapsed))
        #expect(released == .ended(rightOption, .released(.hold, at: at(400))))
        #expect(lapsed != released)
    }

    /// While latched, any configured chord ends the listening, not only the one that
    /// began it.
    @Test func anyChordPressEndsALatchedSession() {
        var keyboard = Keyboard(modes: [rightOption, command])
        _ = keyboard.press(.rightOption, at: 0)
        _ = keyboard.release(.rightOption, at: 100)
        _ = keyboard.press(.leftShift, at: 1000)
        #expect(keyboard.press(.rightOption, at: 1010) == ended(rightOption, .tap, at: 1010))
    }
}
