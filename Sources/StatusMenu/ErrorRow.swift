import AppKit

/// A row of the status item's menu that reports a failure, and puts its full text on the
/// pasteboard when it is clicked, so the person can paste it into a report or a search.
///
/// The text is kept rather than read back off the title, since the menu may draw a long title
/// shortened.
///
/// [LAW:one-type-per-behavior] Every error the menu shows is one of these, so what marks a row
/// as an error is the type and nothing else.
public final class ErrorRow: NSMenuItem {
    public let text: String
    private let clipboard: Clipboard
    private let copied: @MainActor (Clipboard.Copied) -> Void

    /// - Parameter copied: told after each click what went onto `clipboard`.
    public init(_ text: String, copyingTo clipboard: Clipboard, copied: @escaping @MainActor (Clipboard.Copied) -> Void) {
        self.text = text
        self.clipboard = clipboard
        self.copied = copied
        super.init(title: text, action: #selector(copyText), keyEquivalent: "")
        target = self
        image = Self.warningSign
    }

    /// The warning sign in the colours macOS draws it in, so a failure stands out from the
    /// readouts around it the moment the menu opens. Not a template: a menu draws a template
    /// image in its text colour, which is the colour of every other row.
    private static var warningSign: NSImage {
        NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")!
            .withSymbolConfiguration(.preferringMulticolor())!
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("an ErrorRow is made from its text, never decoded")
    }

    /// AppKit sends a menu item's action on the main thread.
    @MainActor @objc private func copyText() {
        copied(clipboard.copy(text))
    }
}
