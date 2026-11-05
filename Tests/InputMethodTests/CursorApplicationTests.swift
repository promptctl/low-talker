@testable import InputMethod
import Testing

/// Which app a client's cursor belongs to: its own name, except for the client of an Open or
/// Save panel, which belongs to the app that put the panel up. A table, so each row is a test.
@Suite struct CursorApplicationTests {
    private static let service = "com.apple.appkit.xpc.openAndSavePanelService"

    @Test(arguments: [nil, "", "com.apple.installer", Self.service] as [String?])
    func anOrdinaryClientIsTheAppItSaysItIs(inFront: String?) {
        #expect(CursorApplication.named(by: "com.example.editor", inFront: inFront) == "com.example.editor")
    }

    @Test func thePanelServiceBelongsToTheAppInFront() {
        #expect(CursorApplication.named(by: Self.service, inFront: "com.apple.installer") == "com.apple.installer")
    }

    /// With no app to be its host the panel's client is no cursor, which is a refusal the
    /// person reads rather than words committed for an app nobody can name.
    @Test(arguments: [nil, "", Self.service] as [String?])
    func thePanelServiceWithNoHostIsNoCursor(inFront: String?) {
        #expect(CursorApplication.named(by: Self.service, inFront: inFront) == nil)
    }

    @Test(arguments: [nil, ""] as [String?])
    func aClientThatNamesNoAppIsNoCursor(named: String?) {
        #expect(CursorApplication.named(by: named, inFront: "com.apple.installer") == nil)
    }
}
