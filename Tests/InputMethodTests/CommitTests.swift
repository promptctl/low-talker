import Foundation
@testable import InputMethod
import Insertion
import Testing

/// What a request comes to against a reading of the field, with no client at all.
/// [LAW:behavior-not-structure]
@Suite struct CommitTests {
    private static let atTheSelection = NSRange(location: NSNotFound, length: 0)

    private static func reading(before: String, selected: String = "", after: String = "") -> FieldReading {
        .readable(DocumentContext(selection: NSRange(location: before.utf16.count, length: selected.utf16.count), selected: selected,
                                  before: before, after: after))
    }

    /// A dictation into a field that could not be read goes in as heard, at the selection, and
    /// nothing says what it replaced.
    @Test func aDictationIntoAnUnreadableFieldGoesInAsHeard() throws {
        let commit = try Commit.decide(InsertRequest(" hello.", into: .cursorInFront), against: .unreadable(.noDocumentAccess)).get()
        #expect(commit == Commit(text: " hello.", replacementRange: Self.atTheSelection, fitting: .unfitted(.noDocumentAccess), replaced: nil))
    }

    /// A dictation replaces the selection, counted in characters as a person counts them.
    @Test func aDictationCountsTheSelectionItReplaces() throws {
        let commit = try Commit.decide(InsertRequest(" smile", into: .cursorInFront), against: Self.reading(before: "a ", selected: "🫠🫠")).get()
        #expect(commit == Commit(text: "smile", replacementRange: Self.atTheSelection, fitting: .fitted([.trimmed]), replaced: 2))
    }

    /// A take-back from a field that could not be read, or whose caret is a selection, is not
    /// committed, and says why.
    @Test func aTakeBackThatCannotBeProvedIsNotCommitted() {
        let request = InsertRequest("", into: .app("com.example.editor"), replacing: "hello")
        #expect(Commit.decide(request, against: .unreadable(.selectionNotFound)) == .failure(.unreadable(.selectionNotFound)))
        #expect(Commit.decide(request, against: Self.reading(before: "say ", selected: "hello")) == .failure(.unfound(.textIsSelected(length: 5))))
        #expect(Commit.decide(request, against: Self.reading(before: "say goodbye")) == .failure(.unfound(.differs)))
    }
}
