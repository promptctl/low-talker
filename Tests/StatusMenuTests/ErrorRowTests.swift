import AppKit
@testable import StatusMenu
import Testing

@MainActor @Suite struct ErrorRowTests {
    /// A pasteboard of its own, so the person's clipboard is never read or written, and
    /// released once the test is done with it.
    private func withScratch(_ test: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: .init("MenuBarPresenceTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try test(pasteboard)
    }

    /// What replacing the pasteboard does is ClipboardTests'; a row copies its full text, not
    /// the title a menu may shorten, and says what went.
    @Test func aClickCopiesTheRowsFullTextAndSaysSo() throws {
        try withScratch { pasteboard in
            let text = "Your last dictation was not placed: " + String(repeating: "a reason long enough that a menu would shorten it ", count: 20) + "."
            var reported: [Clipboard.Copied] = []
            let row = ErrorRow(text, copyingTo: Clipboard(pasteboard)) { reported.append($0) }

            // A click, as AppKit sends it: the item's action to its target.
            let action = try #require(row.action)
            #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))

            #expect(pasteboard.string(forType: .string) == text)
            #expect(reported == [Clipboard.Copied(characters: text.count, taken: true)])
        }
    }

    @Test func theRowCarriesTheWarningSignInItsOwnColours() throws {
        try withScratch { pasteboard in
            let sign = try #require(ErrorRow("Model: it did not load", copyingTo: Clipboard(pasteboard)) { _ in }.image)
            // A menu draws a template image, or a sign in one colour, in its text colour, as
            // plain as the rows around it.
            #expect(!sign.isTemplate)
            #expect(sign.symbolConfiguration == .preferringMulticolor())
            #expect(sign.accessibilityDescription == "Error")
        }
    }

    /// A menu disables any item nothing answers the click of.
    @Test func aMenuEnablesTheRow() {
        // A menu asks the application who answers each item, and with no application it
        // disables every item. The app's menu always has one.
        _ = NSApplication.shared
        withScratch { pasteboard in
            let menu = NSMenu()
            let row = ErrorRow("Config: it cannot be read", copyingTo: Clipboard(pasteboard)) { _ in }
            menu.addItem(row)
            menu.update()
            #expect(row.isEnabled)
        }
    }
}
