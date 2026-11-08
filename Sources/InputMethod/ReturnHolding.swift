import Synchronization

/// Whether the app holds a bare Return for the words it owes, as the app last said. Off until the
/// app says otherwise, so a fresh input method asks IMK for no key-downs and no key a person types
/// reaches this process, which is how it was before a held Return needed them.
///
/// [LAW:one-source-of-truth] The app's setting is the record; this is the input method's copy of it,
/// told by the app's greetings. [LAW:single-enforcer] `recognizedEvents` and `handle` both read this,
/// so the key-downs are asked for only while it holds.
public nonisolated final class ReturnHolding: Sendable {
    public static let shared = ReturnHolding()

    private let holding = Mutex(false)

    /// Off, as a fresh input method is until the app says otherwise.
    public init() {}

    /// Whether a bare Return is held for the words the app owes.
    public var holds: Bool { holding.withLock { $0 } }

    /// Records what the app said, from its latest greeting.
    public func set(_ holds: Bool) { holding.withLock { $0 = holds } }
}
