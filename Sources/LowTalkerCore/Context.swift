/// Everything known before the user spoke, as the session reports it; nothing writes it
/// after the hotkey goes down.
public struct Context: Hashable, Sendable {
    /// The mode whose chord started listening. The chord selects it; the transcript never does.
    public let mode: Mode
    public let press: PressKind
    public let frontmostApp: BundleID

    public init(mode: Mode, press: PressKind, frontmostApp: BundleID) {
        self.mode = mode
        self.press = press
        self.frontmostApp = frontmostApp
    }
}

/// A short press toggles listening; a long one is push-to-talk. The threshold belongs
/// to the hotkey, which resolves it before a Context exists.
public enum PressKind: String, Hashable, Sendable {
    case tap, hold
}
