/// Whether a status item came on screen in the time macOS takes to place one, which is what
/// separates an icon shown from one kept out of the menu bar.
///
/// Measured with probe status items on macOS 26.5 (u2) and 15.0 (studious), 2026-10-18. One
/// macOS shows reads visible within 0.4 s of being made, a full-screen app in front
/// included. One kept out never reads visible: macOS 26 parks it off screen while the row it
/// is filed under is off in System Settings > Menu Bar, and Bartender 5 parks the items it
/// hides the same way. With the menu bar set to hide itself, a shown item also reads
/// hidden until the bar slides down, and `NSMenu.menuBarVisible()` reads false, which is
/// what `menuBarHidden` keeps from being taken for a hidden icon.
public struct StatusItemSighting: Equatable, Sendable {
    /// How long a new status item is given to come on screen before it is judged. Twenty-five
    /// times the slowest placing measured, for a launch at login on a busy Mac.
    /// [LAW:no-ambient-temporal-coupling] A stated deadline the verdict is taken at, not a
    /// delay waiting for something to settle: nothing seen after it changes the verdict.
    public static let deadline: Duration = .seconds(10)

    /// When the item was made, which every reading is timed from.
    public let made: ContinuousClock.Instant
    /// How long after it was made the item was first on screen, and nil while it never has been.
    public private(set) var shownAfter: Duration?

    public init(made: ContinuousClock.Instant) {
        self.made = made
    }

    /// One reading of the item's window, taken at `moment`.
    public mutating func saw(onScreen: Bool, at moment: ContinuousClock.Instant) {
        guard onScreen, shownAfter == nil else { return }
        shownAfter = moment - made
    }

    public func verdict(menuBarShown: Bool) -> Verdict {
        if let shownAfter { return .shown(after: shownAfter) }
        return menuBarShown ? .hidden : .menuBarHidden
    }

    public enum Verdict: Equatable, Sendable, CustomStringConvertible {
        case shown(after: Duration)
        /// Never on screen while the menu bar was: kept out of it.
        case hidden
        /// Never on screen, with the menu bar itself hidden, so nothing could be judged.
        case menuBarHidden

        public var description: String {
            let deadline = "\(StatusItemSighting.deadline.components.seconds) s"
            return switch self {
            case .shown(let after): "icon shown \(Int(after / .milliseconds(1))) ms after it was made"
            case .hidden: "icon not shown in the \(deadline) after it was made, while the menu bar was"
            case .menuBarHidden: "icon not shown in the \(deadline) after it was made, but the menu bar was hidden too, so it was not judged"
            }
        }
    }
}
