import Foundation
import InputSource

/// The input method as a test installs it: switched on or off, selected or not, and each step
/// refused when the test says, with no text input system behind it.
/// `InputMethodInstallationContract` holds it to what `InstalledInputMethod` does.
/// [LAW:one-type-per-behavior]
@MainActor
public final class FakeInputMethodInstallation: InputMethodInstallation {
    public static let installed = URL(fileURLWithPath: "/Library/Input Methods/LowTalker Input.app")

    public private(set) var isSwitchedOn: Bool
    public private(set) var isSelected = false
    /// Whether macOS's dialog is up, asking the person, after a `switchOn` they have not answered.
    public private(set) var asking = false
    /// What the next `select` throws, or nil to select.
    public var selectRefusal: InputMethodFailure?
    /// What the next `switchOn` throws, or nil to ask the person.
    public var switchOnRefusal: InputMethodFailure?
    /// How many times it has been selected.
    public private(set) var selects = 0

    public init(switchedOn: Bool = true) {
        isSwitchedOn = switchedOn
    }

    public func bundle() throws -> URL { Self.installed }

    public func select() async throws -> InputMethodReadiness {
        selects += 1
        if let selectRefusal { throw selectRefusal }
        guard isSwitchedOn else { return .switchedOff }
        isSelected = true
        return .selected
    }

    /// Puts macOS's dialog up and returns with it still up, as `InstalledInputMethod` does: the
    /// person's answer is `answer(allowing:)`, after.
    public func switchOn() async throws {
        if let switchOnRefusal { throw switchOnRefusal }
        asking = true
    }

    /// The person answers the dialog `switchOn` put up.
    public func answer(allowing: Bool) {
        precondition(asking, "answered with no dialog up")
        asking = false
        isSwitchedOn = isSwitchedOn || allowing
    }

    /// Another source chosen from the Input menu.
    public func deselect() { isSelected = false }
}
