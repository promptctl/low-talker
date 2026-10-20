/// A short press toggles listening; a long one is push-to-talk. The threshold belongs
/// to the hotkey, which resolves it as the key comes up.
public enum PressKind: String, Hashable, Sendable {
    case tap, hold
}
