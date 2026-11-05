import LowTalkerCore

extension Hotkey {
    /// Starts watching, with `dictation` hearing every press.
    ///
    /// [LAW:single-enforcer] The one place a press reaches the loop and the loop's answer reaches
    /// the hotkey: a press `dictation` refuses at key-down is not latched as a tap, so the next
    /// press of the chord begins a press instead of ending a refused one. The app and the tests
    /// start the hotkey through here. `began` runs before each press begins, for what the caller
    /// keeps of the press before it.
    public func start(feeding dictation: Dictation, began: @escaping @MainActor () -> Void = {}) throws {
        try start { transition in
            if case .began = transition { began() }
            return dictation.press(transition)
        }
    }
}
