/// Everything known before the user spoke, as the session reports it; nothing writes it
/// after the hotkey goes down. The mode the press began in is its report's to say.
public struct Context: Hashable, Sendable {
    public let press: PressKind
    public let frontmostApp: BundleID

    public init(press: PressKind, frontmostApp: BundleID) {
        self.press = press
        self.frontmostApp = frontmostApp
    }
}

/// A short press toggles listening; a long one is push-to-talk. The threshold belongs
/// to the hotkey, which resolves it before a Context exists.
public enum PressKind: String, Hashable, Sendable {
    case tap, hold
}
