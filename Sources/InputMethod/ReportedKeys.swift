import Synchronization

/// The virtual key codes the app asked to hear of, as the app last said. Empty until it says so,
/// so a fresh input method reports no key at all.
///
/// [LAW:one-source-of-truth] The app's key table is the record; this is the input method's copy.
/// The handler reports a key only when it is in here, and reports it without waiting: a key that
/// is reported passes on as it would have.
public nonisolated final class ReportedKeys: Sendable {
    public static let shared = ReportedKeys()

    private let keys = Mutex<Set<UInt16>>([])

    /// Empty, as a fresh input method is until the app says otherwise.
    public init() {}

    /// Whether a press of `keyCode` is reported to the app.
    public func reports(_ keyCode: UInt16) -> Bool { keys.withLock { $0.contains(keyCode) } }

    /// Records what the app said, from its latest greeting.
    public func set(_ keyCodes: [UInt16]) { keys.withLock { $0 = Set(keyCodes) } }
}
