import Foundation
@testable import InputMethod
import Insertion
import Testing

/// What a request comes to against a reading of the field and the cursor's last commit, with no
/// client at all.
/// [LAW:behavior-not-structure]
@Suite struct CommitTests {
    private static let atTheSelection = NSRange(location: NSNotFound, length: 0)

    private static func reading(before: String, selected: String = "", after: String = "") -> FieldReading {
        .readable(DocumentContext(selection: NSRange(location: before.utf16.count, length: selected.utf16.count), selected: selected,
                                  before: before, after: after))
    }

    /// The commit a dictation of `text` made at `location`, fitted to nothing in particular.
    private static func committed(_ text: String, at location: Int) -> Commit {
        Commit(text: text, replacementRange: atTheSelection,
               field: .read(Commit.Read(filled: NSRange(location: location, length: text.utf16.count), replaced: 0, before: .field, rules: [])))
    }

    /// "Dear Sam." and then " Hello", which went in at 9, as a field reads it that shows blanks
    /// where the words it was just handed went.
    private static let hello = committed(" Hello", at: 9)
    private static let blanksAfterHello = reading(before: "Dear Sam." + String(repeating: " ", count: 6))

    /// A dictation into a field that could not be read goes in as heard, at the selection, and
    /// nothing says what it replaced, whatever the last commit was.
    @Test(arguments: [nil, hello])
    func aDictationIntoAnUnreadableFieldGoesInAsHeard(after last: Commit?) throws {
        let commit = try Commit.decide(InsertRequest(" hello.", into: .cursorInFront), against: .unreadable(.noDocumentAccess), after: last).get()
        #expect(commit == Commit(text: " hello.", replacementRange: Self.atTheSelection, field: .unreadable(.noDocumentAccess)))
        #expect(commit.caret == nil)
    }

    /// A dictation replaces the selection, counted in characters as a person counts them, and
    /// fills as many UTF-16 units from the selection's start as its words take.
    @Test func aDictationCountsTheSelectionItReplaces() throws {
        let commit = try Commit.decide(InsertRequest(" smile", into: .cursorInFront), against: Self.reading(before: "a ", selected: "🫠🫠"),
                                       after: nil).get()
        #expect(commit == Commit(text: "smile", replacementRange: Self.atTheSelection,
                                 field: .read(Commit.Read(filled: NSRange(location: 2, length: 5), replaced: 2, before: .field, rules: [.trimmed]))))
        #expect(commit.caret == NSRange(location: 7, length: 0))
    }

    /// At the caret the last commit left, its words are the text before the caret, whatever the
    /// field reads there: words continuing it are spaced from it, and not capitalized because the
    /// field read blank.
    @Test func aDictationAtTheLastCommitsCaretIsFittedAfterItsWords() throws {
        let commit = try Commit.decide(InsertRequest(" there", into: .cursorInFront), against: Self.blanksAfterHello, after: Self.hello).get()
        #expect(commit == Commit(text: " there", replacementRange: Self.atTheSelection,
                                 field: .read(Commit.Read(filled: NSRange(location: 15, length: 6), replaced: 0,
                                                          before: .lastCommit(NSRange(location: 9, length: 6)), rules: [.trimmed, .spacedBefore]))))
    }

    /// The last commit's own sentence end still starts a sentence.
    @Test func aCapitalStillComesAfterTheLastCommitsSentenceEnd() throws {
        let last = Self.committed(" Hello there.", at: 9)
        let reading = Self.reading(before: "Dear Sam." + String(repeating: " ", count: 13))
        let commit = try Commit.decide(InsertRequest(" how are you", into: .cursorInFront), against: reading, after: last).get()
        #expect(commit.text == " How are you")
        #expect(commit.field == .read(Commit.Read(filled: NSRange(location: 22, length: 12), replaced: 0,
                                                  before: .lastCommit(NSRange(location: 9, length: 13)), rules: [.trimmed, .capitalized, .spacedBefore])))
    }

    /// Anywhere but the caret the last commit left - short of it, past it, or a selection there -
    /// the field decides, as it reads.
    @Test(arguments: [
        DocumentContext(selection: NSRange(location: 14, length: 0), selected: "", before: "Dear Sam." + String(repeating: " ", count: 5), after: " "),
        DocumentContext(selection: NSRange(location: 16, length: 0), selected: "", before: "Dear Sam." + String(repeating: " ", count: 7), after: ""),
        DocumentContext(selection: NSRange(location: 15, length: 1), selected: "x", before: "Dear Sam." + String(repeating: " ", count: 6), after: ""),
    ])
    func aDictationAnywhereElseIsFittedToTheField(_ context: DocumentContext) throws {
        let commit = try Commit.decide(InsertRequest(" there", into: .cursorInFront), against: .readable(context), after: Self.hello).get()
        let field = try Commit.decide(InsertRequest(" there", into: .cursorInFront), against: .readable(context), after: nil).get()
        #expect(commit == field)
        #expect(commit.text == "There")
        guard case .read(let read) = commit.field else { Issue.record("\(commit)"); return }
        #expect(read.before == .field)
    }

    /// A last commit that left nothing stands over nothing, so the field's own text before the
    /// caret is what the words are fitted to.
    @Test func anEmptyLastCommitLeavesTheFieldsTextBeforeIt() throws {
        let reading = Self.reading(before: "Dear Sam. Hello ")
        let request = InsertRequest(" there", into: .cursorInFront)
        let commit = try Commit.decide(request, against: reading, after: Self.committed("", at: 16)).get()
        #expect(commit.text == "there")
        #expect(commit.text == (try Commit.decide(request, against: reading, after: nil).get().text))
        guard case .read(let read) = commit.field else { Issue.record("\(commit)"); return }
        #expect(read.before == .lastCommit(NSRange(location: 16, length: 0)))
    }

    /// A take-back from a field that could not be read, or whose caret is a selection, is not
    /// committed, and says why.
    @Test func aTakeBackThatCannotBeProvedIsNotCommitted() {
        let request = InsertRequest("", into: .app("com.example.editor"), replacing: "hello")
        #expect(Commit.decide(request, against: .unreadable(.selectionNotFound), after: nil) == .failure(.unreadable(.selectionNotFound)))
        #expect(Commit.decide(request, against: Self.reading(before: "say ", selected: "hello"), after: nil)
            == .failure(.unfound(.textIsSelected(length: 5))))
        #expect(Commit.decide(request, against: Self.reading(before: "say goodbye"), after: nil) == .failure(.unfound(.differs)))
    }

    /// A take-back is proved against what the field reads, never the last commit: at the caret
    /// the last commit left, a field reading blanks there has no words to take back.
    @Test func aTakeBackAtTheLastCommitsCaretIsProvedAgainstTheField() {
        let request = InsertRequest("", into: .app("com.example.editor"), replacing: "Hello")
        #expect(Commit.decide(request, against: Self.blanksAfterHello, after: Self.hello) == .failure(.unfound(.differs)))
    }

    /// What the commit's event says: the rules in the order they apply, and where the text before
    /// the words came from.
    @Test func theFieldReadSaysWhatFittingDid() {
        let filled = NSRange(location: 3, length: 7)
        #expect(Commit.Read(filled: filled, replaced: 0, before: .field, rules: [.spacedAfter, .periodDropped, .capitalized, .spacedBefore, .trimmed])
            .description == "fitted: edge whitespace trimmed, closing period dropped, capitalized, space before, space after; the text before it from the field")
        #expect(Commit.Read(filled: filled, replaced: 0, before: .lastCommit(NSRange(location: 0, length: 3)), rules: []).description
            == "fitted, unchanged; the text before it from the last commit, its 3 units at {0, 3}")
        #expect(Commit.Field.unreadable(.noDocumentAccess).description == "unfitted, because it gives no document access")
    }
}
