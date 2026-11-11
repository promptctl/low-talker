import AppKit
@testable import StatusMenu
import Testing

@MainActor @Suite struct ClipboardTests {
    /// A copy replaces everything the pasteboard held, of every type, with the text, and says
    /// how many characters it put there.
    @Test func aCopyReplacesWhatWasCopiedAndSaysHowMuch() {
        let pasteboard = NSPasteboard(name: .init("ClipboardTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what the person had copied", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: .png)

        let copied = Clipboard(pasteboard).copy("Hello world.")

        #expect(copied == Clipboard.Copied(characters: 12, taken: true))
        #expect(pasteboard.string(forType: .string) == "Hello world.")
        #expect(pasteboard.data(forType: .png) == nil)
    }
}
