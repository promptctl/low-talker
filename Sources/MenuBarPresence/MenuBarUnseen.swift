import AppKit

/// Why nobody could see the menu bar, whose items then never read visible however macOS
/// treats them.
public enum MenuBarUnseen: String, Equatable, Sendable {
    /// Another person's login session was on screen, as after a fast user switch, or this
    /// process had no window server session at all.
    case sessionNotOnConsole = "this login session was not the one on screen"
    case screenLocked = "the screen was locked"
    case displayAsleep = "the display was asleep"
    /// The menu bar is set to hide itself and had not slid down.
    case menuBarHidden = "the menu bar was hidden"

    /// Why nobody can see the menu bar now, or nil when it is in view.
    @MainActor public static func now() -> MenuBarUnseen? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey] as? Bool == true
        else { return .sessionNotOnConsole }
        // Undocumented key, read the same way by every app that asks whether the screen is locked.
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return .screenLocked }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return .displayAsleep }
        return NSMenu.menuBarVisible() ? nil : .menuBarHidden
    }
}
