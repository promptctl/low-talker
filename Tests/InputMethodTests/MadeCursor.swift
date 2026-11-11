@testable import InputMethod
import InputMethodFakes
import Testing

extension FakeTextInputClient {
    /// The cursor `activateServer` makes of this field's client while `frontmost` is in front.
    /// A field it would make none of fails the case that asked, not the run.
    @MainActor
    func cursor(whileInFrontIs frontmost: String? = nil) throws -> Client {
        try #require(Client(self, inFront: frontmost))
    }
}

/// In these cases a cursor stands for a controller of its own, as `IMKServer` builds one per client,
/// so `left(cursor)` and `typedInto(cursor)` are that controller's. Only here: the input method
/// itself cannot hand `FocusedClient` a cursor where a controller is meant.
extension Client: InputController {}

extension FocusedClient {
    /// `cursor` taken by its own controller, which is itself.
    @MainActor
    func took(_ cursor: Client) { took(cursor, by: cursor) }
}
