import AppKit

/// Where a copy the person asks for goes. A click is the person asking for the copy, so
/// replacing whatever the pasteboard held is what they asked for.
///
/// [LAW:single-enforcer] Every copy the app makes goes through here: an error row of the menu
/// and the word box's Copy alike.
@MainActor
public struct Clipboard {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// What one copy put on the pasteboard. The text itself is left out: what is copied can be
    /// the person's dictated words.
    public struct Copied: Equatable, Sendable {
        public let characters: Int
        /// False when the pasteboard refused the text, which leaves it empty.
        public let taken: Bool
    }

    /// Puts `text` on the pasteboard in place of everything it held.
    public func copy(_ text: String) -> Copied {
        pasteboard.clearContents()
        return Copied(characters: text.count, taken: pasteboard.setString(text, forType: .string))
    }
}
