import LowTalkerCore

extension Hotkey {
    /// Starts watching, with `dictation` hearing every press.
    ///
    /// [LAW:single-enforcer] The one place a press reaches the loop and the loop's answer reaches
    /// the hotkey: a press `dictation` refuses at key-down is not latched as a tap, so the next
    /// press of the chord begins a press instead of ending a refused one. The app and the tests
    /// start the hotkey through here. `began` runs before each press begins, for what the caller
    /// keeps of the press before it.
    ///
    /// [LAW:one-source-of-truth] The loop times each press from the stamps this hotkey hands it,
    /// so the two read one clock, and a loop timed on another is refused here.
    public func start(feeding dictation: Dictation, began: @escaping @MainActor () -> Void = {}) throws {
        precondition(dictation.clock == clock, "the loop is timed on a clock other than the one its key events are stamped on")
        try start { transition in
            if case .began = transition { began() }
            return dictation.press(transition)
        }
    }
}
