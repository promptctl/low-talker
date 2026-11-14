import Foundation
@testable import InputMethod
import Testing

/// What a transcript becomes against the text around where it goes, and which rules said so.
@Suite struct FittingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let before: String
        var selected = ""
        let after: String
        let transcript: String
        let fitted: String
        let rules: Set<Fitting.Rule>

        var testDescription: String { name }

        var reading: FieldReading {
            .readable(DocumentContext(selection: NSRange(location: before.utf16.count, length: selected.utf16.count),
                                      selected: selected, before: before, after: after))
        }
    }

    static let cases: [Case] = [
        Case(name: "the field's start", before: "", after: "", transcript: " hello world.", fitted: "Hello world.", rules: [.capitalized]),
        Case(name: "mid-line, the engine's space replaced by one", before: "Say", after: "", transcript: " hello", fitted: " hello", rules: [.spacedBefore]),
        Case(name: "mid-line after a space", before: "Say ", after: "", transcript: " hello", fitted: "hello", rules: []),
        Case(name: "after a newline", before: "Hi.\n", after: "", transcript: "next", fitted: "Next", rules: [.capitalized]),
        Case(name: "after a newline and indentation", before: "Hi\n  ", after: "", transcript: "next", fitted: "Next", rules: [.capitalized]),
        Case(name: "after a period", before: "Hi.", after: "", transcript: "there", fitted: " There", rules: [.capitalized, .spacedBefore]),
        Case(name: "after a question mark and a space", before: "Why? ", after: "", transcript: "because", fitted: "Because", rules: [.capitalized]),
        Case(name: "after an exclamation mark", before: "Stop!", after: "", transcript: "now", fitted: " Now", rules: [.capitalized, .spacedBefore]),
        Case(name: "after an ellipsis", before: "Well… ", after: "", transcript: "fine", fitted: "Fine", rules: [.capitalized]),
        Case(name: "after a quote a period closes", before: "He said \"Stop.\" ", after: "", transcript: "then", fitted: "Then", rules: [.capitalized]),
        Case(name: "after a quote no period closes", before: "said \"hi\"", after: "", transcript: "then", fitted: " then", rules: [.spacedBefore]),
        Case(name: "before a word", before: "", after: "world", transcript: "hello", fitted: "Hello ", rules: [.capitalized, .spacedAfter]),
        Case(name: "before a number", before: "Room ", after: "4", transcript: "one", fitted: "one ", rules: [.spacedAfter]),
        Case(name: "before punctuation", before: "Say ", after: ", please", transcript: "hello", fitted: "hello", rules: []),
        Case(name: "before a sentence that continues", before: "I think ", after: "and more", transcript: "so.", fitted: "so ", rules: [.closingDropped, .spacedAfter]),
        Case(name: "before a space and a sentence that continues", before: "I think ", after: " and more", transcript: "so?!", fitted: "so", rules: [.closingDropped]),
        Case(name: "before a sentence that starts", before: "I think ", after: " And more", transcript: "so.", fitted: "so.", rules: []),
        Case(name: "before a new line that continues", before: "I think ", after: "\nand more", transcript: "so.", fitted: "so.", rules: []),
        Case(name: "a closing mark alone is kept", before: "Yes", after: "and", transcript: ".", fitted: ". ", rules: [.spacedAfter]),
        Case(name: "after an opening bracket", before: "note (", after: "", transcript: "see", fitted: "see", rules: []),
        Case(name: "after an opening curly quote", before: "He said “", after: "", transcript: "go", fitted: "go", rules: []),
        Case(name: "after an opening straight quote", before: "He said \"", after: "", transcript: "go", fitted: "go", rules: []),
        Case(name: "a quote opening the field", before: "", after: "", transcript: "\"wow\"", fitted: "\"Wow\"", rules: [.capitalized]),
        Case(name: "starting with a comma", before: "Well", after: "", transcript: ", then", fitted: ", then", rules: []),
        Case(name: "a number first", before: "", after: "", transcript: "3 apples", fitted: "3 apples", rules: []),
        Case(name: "already capital", before: "", after: "", transcript: "Hello", fitted: "Hello", rules: []),
        Case(name: "after an emoji", before: "👍", after: "", transcript: "nice", fitted: " nice", rules: [.spacedBefore]),
        Case(name: "blank", before: "Hi", after: "there", transcript: "  ", fitted: "", rules: []),
        Case(name: "a selection replaced, judged by what is around it", before: "Hi. ", selected: "world", after: "", transcript: "there", fitted: "There", rules: [.capitalized]),
        Case(name: "a selection replaced mid-sentence", before: "a", selected: "big", after: "dog", transcript: "small.", fitted: " small ", rules: [.closingDropped, .spacedBefore, .spacedAfter]),
    ]

    @Test(arguments: cases)
    func aTranscriptIsFittedToTheTextAroundIt(_ fitting: Case) {
        #expect(Fitting.fit(fitting.transcript, to: fitting.reading) == Fitting(text: fitting.fitted, outcome: .fitted(fitting.rules)))
    }

    /// A field that cannot be read gets the transcript back verbatim, its whitespace included, with
    /// the client's reason.
    @Test(arguments: [Unreadable.noDocumentAccess, .selectionNotFound, .impossibleSelection(NSRange(location: -1, length: 0)),
                      .contradicted(asked: NSRange(location: 0, length: 4), answered: nil)])
    func anUnreadableFieldGetsTheTranscriptUnchanged(_ reason: Unreadable) {
        #expect(Fitting.fit(" hello.", to: .unreadable(reason)) == Fitting(text: " hello.", outcome: .unfitted(reason)))
    }

    /// What the commit's event says: the rules in the order they apply, or the reason.
    @Test func theOutcomeSaysWhatFittingDid() {
        #expect(Fitting.Outcome.fitted([.spacedAfter, .closingDropped, .capitalized, .spacedBefore]).description
            == "fitted: closing mark dropped, capitalized, space before, space after")
        #expect(Fitting.Outcome.fitted([]).description == "fitted, unchanged")
        #expect(Fitting.Outcome.unfitted(.noDocumentAccess).description == "unfitted, because it gives no document access")
    }
}
