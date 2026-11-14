import Foundation

/// The input method as this installation holds it: the bundle its package installed, selected at
/// every rebuild, switched on only from the step a person starts, and read for whether it is on
/// and in use.
///
/// [LAW:effects-at-boundaries] Every call reads or writes the text input system, so the app is
/// handed one of these, and a test one whose answers it sets. `InputMethodInstallationContract`
/// holds the fake to what `InstalledInputMethod` does.
@MainActor
public protocol InputMethodInstallation {
    /// The installed bundle.
    func bundle() throws -> URL
    /// Registers and selects the input method, stopping at `switchedOff` while a person has not
    /// switched it on. Puts no dialog on screen.
    func select() async throws -> InputMethodReadiness
    /// Switches the input method on, which is where macOS asks the person.
    func switchOn() async throws
    /// Whether a person has switched it on.
    var isSwitchedOn: Bool { get }
    /// Whether its source is the one in use.
    var isSelected: Bool { get }
}

extension InstalledInputMethod: InputMethodInstallation {
    public func select() async throws -> InputMethodReadiness {
        try await select(settling: .seconds(3))
    }

    public func switchOn() async throws {
        try await switchOn(settling: .seconds(3))
    }

    public var isSwitchedOn: Bool { Self.isSwitchedOn() }

    public var isSelected: Bool { Self.isSelected() }
}
