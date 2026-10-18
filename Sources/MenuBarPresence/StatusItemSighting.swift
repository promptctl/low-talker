/// Whether a status item came on screen in the time macOS takes to place one, which is what
/// separates an icon shown from one kept out of the menu bar.
///
/// Measured with probe status items on macOS 26.5 (u2) and 15.0 (studious), 2026-10-18. One
/// macOS shows reads visible within 0.4 s of being made, a full-screen app in front
/// included. One kept out never reads visible: macOS 26 parks it off screen while the row it
/// is filed under is off in System Settings > Menu Bar, and Bartender 5 parks the items it
/// hides the same way. A shown item also never reads visible while nobody can see the menu
/// bar at all, which `MenuBarUnseen` names so it is not taken for a hidden icon, nor in the
/// moments after the menu bar comes back into view, which `placing` allows for.
public struct StatusItemSighting: Sendable {
    /// How long a new status item is given to come on screen before it is judged. Twenty-five
    /// times the slowest placing measured, for a launch at login on a busy Mac.
    /// [LAW:no-ambient-temporal-coupling] A stated deadline the verdict is taken at, not a
    /// delay waiting for something to settle: nothing seen after it changes the verdict.
    public static let deadline: Duration = .seconds(10)
    /// How long before the deadline the menu bar is read as well as at it, so an icon never
    /// seen is judged hidden only when the menu bar was in view that long. Five times the
    /// slowest placing measured.
    public static let placing: Duration = .seconds(2)

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

    /// - Parameter menuBar: the readings of the menu bar taken `placing` before the deadline
    ///   and at it, each why nobody could see it, or nil when it was in view.
    public func verdict(menuBar: [MenuBarUnseen?]) -> Verdict {
        if let shownAfter { return .shown(after: shownAfter) }
        if let why = menuBar.compactMap({ $0 }).last { return .unjudged(why) }
        return .hidden
    }

    public enum Verdict: Equatable, Sendable, CustomStringConvertible {
        case shown(after: Duration)
        /// Never on screen while the menu bar was in view: kept out of it.
        case hidden
        /// Never on screen, with the menu bar itself out of view, so nothing could be judged.
        case unjudged(MenuBarUnseen)

        public var description: String {
            let deadline = "\(StatusItemSighting.deadline.components.seconds) s"
            return switch self {
            case .shown(let after): "icon shown \(Int(after / .milliseconds(1))) ms after it was made"
            case .hidden: "icon not shown in the \(deadline) after it was made, while the menu bar was in view"
            case .unjudged(let why): "icon not shown in the \(deadline) after it was made, but \(why.rawValue), so it was not judged"
            }
        }
    }
}
