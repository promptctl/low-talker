import AppKit
import Identity

/// What the app tells a person whose menu bar is not showing its icon, which is the app's
/// only way in, and whether they have asked not to be told again.
///
/// An icon a menu bar manager hides is one its owner hid on purpose, and reads exactly like
/// one macOS keeps out (see `StatusItemSighting`), so being told at every launch is theirs to
/// turn off. [LAW:no-silent-failure] Off is their choice; until they make it, a launch with
/// no icon is said.
public struct HiddenIconNotice {
    public let title = "\(AppIdentity.displayName) is running, but its icon is not in the menu bar"
    public let body: String
    /// What the person can do about it, in the order they are offered, the first the default.
    public let answers: [Answer]

    public enum Answer: Equatable, Sendable {
        /// The System Settings pane with the switch that lets an app's icon into the menu bar.
        case openMenuBarSettings(URL)
        case keepRunning
        case quit

        public var title: String {
            switch self {
            case .openMenuBarSettings: "Open Menu Bar Settings"
            case .keepRunning: "Keep Running"
            case .quit: "Quit \(AppIdentity.displayName)"
            }
        }
    }

    private let defaults: UserDefaults
    static let silencedKey = "hiddenIconNoticeSilenced"

    /// - Parameter allowList: whether this macOS keeps the Allow in the Menu Bar list.
    public init(defaults: UserDefaults = .standard, allowList: Bool) {
        self.defaults = defaults
        let name = AppIdentity.displayName
        let lines = [
            "Its menu is the only way to reach \(name)'s settings, its setup and Quit.",
            allowList ? "macOS shows it only while \(name) is switched on under Allow in the Menu Bar, in System Settings > Menu Bar." : nil,
            "If an app that manages your menu bar is hiding it, show it there.",
            "On a screen with a notch, an icon the menu bar has no room for sits behind it. Quitting other menu bar apps makes room.",
        ]
        body = lines.compactMap { $0 }.joined(separator: "\n\n")
        // macOS 26 lists every app under Allow in the Menu Bar in its Menu Bar pane, whose
        // identifier this is. macOS 15 has no such list, so no pane to send anyone to.
        let settings: Answer? = allowList ? .openMenuBarSettings(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!) : nil
        answers = [settings, .keepRunning, .quit].compactMap { $0 }
    }

    /// The answer whose button ended the alert with `response`, or nil when something other
    /// than a button ended it.
    public func answer(to response: NSApplication.ModalResponse) -> Answer? {
        // The buttons are numbered from the first in the order they were added.
        let button = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answers.indices.contains(button) ? answers[button] : nil
    }

    /// This Mac's notice.
    public static func forThisMac() -> HiddenIconNotice {
        if #available(macOS 26, *) { HiddenIconNotice(allowList: true) } else { HiddenIconNotice(allowList: false) }
    }

    /// Whether the person has asked not to be told again. Unset reads as not asked.
    /// [LAW:one-source-of-truth]
    public var silenced: Bool { defaults.bool(forKey: Self.silencedKey) }

    public func silence() {
        defaults.set(true, forKey: Self.silencedKey)
    }
}
