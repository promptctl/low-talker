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
