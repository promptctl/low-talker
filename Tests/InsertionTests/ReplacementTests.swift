import Foundation
import Testing

import Insertion

/// Words are taken back only when the field proves they are there. [LAW:behavior-not-structure]
/// Held against a string standing in for the document, read the way a client reads it: by
/// UTF-16 range.
@Suite struct ReplacementTests {
    /// A document and its caret, in UTF-16 units, which is how a client counts.
    private struct Field {
        var text: String
        var caret: NSRange

        var utf16: [UInt16] { Array(text.utf16) }

        func substring(_ range: NSRange) -> String? {
            guard range.location >= 0, range.location + range.length <= utf16.count else { return nil }
            return String(decoding: utf16[range.location..<range.location + range.length], as: UTF16.self)
        }

        func range(of replacing: String) -> Result<NSRange, Replacement.Unfound> {
            Replacement.range(of: replacing, selection: { caret }, text: { substring($0) })
        }

        /// What the document is once `replacing` before the caret is replaced by nothing.
        func tookBack(_ range: NSRange) -> String {
            String(decoding: utf16[..<range.location] + utf16[(range.location + range.length)...], as: UTF16.self)
        }
    }

    private static func field(_ text: String) -> Field {
        Field(text: text, caret: NSRange(location: text.utf16.count, length: 0))
    }

    @Test func wordsBeforeTheCaretAreFound() throws {
        let field = Self.field("Dear Sam, hello there")
        let range = try field.range(of: " hello there").get()
        #expect(field.tookBack(range) == "Dear Sam,")
    }

    /// A commit that replaces nothing asks the client nothing, so a client that answers no
    /// selection still takes an ordinary insert.
    @Test func replacingNothingAsksTheClientNothing() throws {
        let range = try Replacement.range(of: "", selection: { Issue.record("the selection was read"); return NSRange(location: NSNotFound, length: 0) },
                                          text: { _ in Issue.record("the text was read"); return nil }).get()
        #expect(range == NSRange(location: NSNotFound, length: 0))
    }

    /// Lengths are UTF-16 units: an emoji is two of them and a decomposed accent two characters
    /// of one.
    @Test(arguments: ["🫠 hello", "cafe\u{301} au lait", "日本語 🇯🇵"])
    func wordsAreMeasuredInUTF16Units(words: String) throws {
        let field = Self.field("before " + words)
        let range = try field.range(of: words).get()
        #expect(range.length == words.utf16.count)
        #expect(field.tookBack(range) == "before ")
    }

    @Test func aClientThatReportsNoSelectionIsRefused() {
        var field = Self.field("hello")
        field.caret = NSRange(location: NSNotFound, length: 0)
        #expect(field.range(of: "hello") == .failure(.noSelection))
    }

    /// A caret the person moved is not where the words ended, and the same text elsewhere in
    /// the document is not them.
    @Test func aMovedCaretIsRefused() {
        var field = Self.field("hello there hello")
        field.caret = NSRange(location: 5, length: 0)
        #expect(field.range(of: "hello") == .success(NSRange(location: 0, length: 5)), "the text happens to be before this caret too")
        field.caret = NSRange(location: 11, length: 0)
        #expect(field.range(of: "hello") == .failure(.differs))
    }

    @Test func textTypedAfterTheWordsIsRefused() {
        let field = Self.field("hello there!")
        #expect(field.range(of: "hello there") == .failure(.differs))
    }

    @Test func aSelectionIsNotACaret() {
        var field = Self.field("hello")
        field.caret = NSRange(location: 3, length: 2)
        #expect(field.range(of: "hello") == .failure(.textIsSelected(length: 2)))
    }

    @Test func fewerCharactersBeforeTheCaretThanTheWordsIsRefused() {
        var field = Self.field("hi")
        field.caret = NSRange(location: 2, length: 0)
        #expect(field.range(of: "hello") == .failure(.fewerBefore(caret: 2, needed: 5)))
    }

    @Test func aClientThatWillNotSayWhatPrecedesTheCaretIsRefused() {
        let result = Replacement.range(of: "hello", selection: { NSRange(location: 5, length: 0) }, text: { _ in nil })
        #expect(result == .failure(.unreadable))
    }
}
