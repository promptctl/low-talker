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

    @Test func aClickReplacesWhatWasCopiedWithTheRowsFullTextAndSaysSo() throws {
        try withScratch { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("what the person had copied", forType: .string)
            pasteboard.setData(Data([1, 2, 3]), forType: .png)
            let text = "Your last dictation was not placed: " + String(repeating: "a reason long enough that a menu would shorten it ", count: 20) + "."
            var reported: [ErrorRow.Copied] = []
            let row = ErrorRow(text, copyingTo: pasteboard) { reported.append($0) }

            // A click, as AppKit sends it: the item's action to its target.
            let action = try #require(row.action)
            #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))

            #expect(pasteboard.data(forType: .png) == nil)
            #expect(pasteboard.string(forType: .string) == text)
            #expect(reported == [ErrorRow.Copied(characters: text.count, taken: true)])
        }
    }

    /// A menu disables any item nothing answers the click of.
    @Test func aMenuEnablesTheRow() {
        withScratch { pasteboard in
            let menu = NSMenu()
            let row = ErrorRow("Config: it cannot be read", copyingTo: pasteboard) { _ in }
            menu.addItem(row)
            menu.update()
            #expect(row.isEnabled)
        }
    }
}
