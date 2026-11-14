@testable import InputMethod
import InputMethodFakes
import Insertion
import Testing

extension FakeTextInputClient {
    /// The cursor `activateServer` makes of this field's client while `frontmost` is in front.
    /// A field it would make none of fails the case that asked, not the run.
    @MainActor
    func cursor(whileInFrontIs frontmost: String? = nil) throws -> Client {
        try #require(Client(self, inFront: frontmost))
    }
}

extension InFront {
    /// What `FocusedClient` would have seen with `application` in front and its one cursor
    /// chosen, or the refusal.
    @MainActor
    static func seen(_ cursor: Result<Client, Refusal>, in application: String = "com.example.editor") -> InFront {
        InFront(frontmost: application, selected: true, cursorApplication: application, cursors: 1, ruledOut: 0,
                field: nil, screens: [], cursor: cursor)
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
