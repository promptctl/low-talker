/// What the app tells the input method on each greeting, so the input method can answer a key at once
/// without asking the app: whether a bare Return is held for the words the app owes, and whether the
/// app's word box is open, which is when Escape is kept for the app and not passed on.
///
/// [LAW:one-source-of-truth] The app is the record of both; the input method keeps the last copy it
/// was told. An insert's greeting carries none, and the input method keeps what it has.
public struct InputMethodState: Codable, Equatable, Sendable {
    /// Whether a bare Return is held until the words the app owes have landed.
    public var holdsReturn: Bool
    /// Whether the app's word box is open.
    public var panelShown: Bool

    public init(holdsReturn: Bool, panelShown: Bool) {
        self.holdsReturn = holdsReturn
        self.panelShown = panelShown
    }

    /// Nothing held and no box open: what a fresh input method has until the app says otherwise.
    public static let none = InputMethodState(holdsReturn: false, panelShown: false)
}
