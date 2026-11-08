import Insertion
import Synchronization

/// What the app last told this input method: whether a bare Return is held, and whether the app's word
/// box is open. The key handler reads these and nothing else.
///
/// [LAW:one-source-of-truth] The app is the record; this is the copy the last greeting left.
public nonisolated final class AppState: Sendable {
    public static let shared = AppState()

    private let state = Mutex(InputMethodState.none)

    /// Nothing held and no box open, as a fresh input method is until the app says otherwise.
    public init() {}

    /// Whether a bare Return is held for the words the app owes.
    public var holdsReturn: Bool { state.withLock { $0.holdsReturn } }

    /// Whether the app's word box is open. Escape is kept for the app while it is.
    public var panelShown: Bool { state.withLock { $0.panelShown } }

    /// Records what the app said, from its latest greeting.
    public func set(_ newState: InputMethodState) { state.withLock { $0 = newState } }
}
