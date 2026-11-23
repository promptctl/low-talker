import Foundation
@testable import InputMethod
import Insertion
import Testing

/// What a request comes to against a reading of the field and the input method's last words in it,
/// with no client at all.
/// [LAW:behavior-not-structure]
@Suite struct CommitTests {
    private static let atTheSelection = NSRange(location: NSNotFound, length: 0)

    private static func reading(before: String, selected: String = "", after: String = "") -> FieldReading {
        .readable(DocumentContext(selection: NSRange(location: before.utf16.count, length: selected.utf16.count), selected: selected,
                                  before: before, after: after))
    }

    private static func blanks(_ count: Int) -> String { String(repeating: " ", count: count) }

    /// A run of `words`, which are never empty here.
    private static func run(_ words: String, endingAt end: Int) -> Commit.Run { Commit.Run(words, endingAt: end)! }

    /// " Hello", put in after "Dear Sam." and so ending at 15.
    private static let hello = run(" Hello", endingAt: 15)

    /// Where the text before a commit's words came from, or nil for a commit into a field that
    /// could not be read.
    private static func source(_ commit: Commit) -> Commit.Before? {
        guard case .fitted(let fitted) = commit.placement else { return nil }
        return fitted.before
    }

    private static func dictating(_ text: String, against reading: FieldReading, after run: Commit.Run?) throws -> Commit {
        try Commit.decide(InsertRequest(text, into: .cursorInFront), against: reading, after: run).get()
    }

    /// A dictation into a field that could not be read goes in as heard, at the selection, nothing
    /// says what it replaced, and it leaves no run, whatever the reason and whatever run was there.
    @Test(arguments: [Unreadable.noDocumentAccess, .selectionNotFound, .impossibleSelection(NSRange(location: -1, length: 0)),
                      .contradicted(asked: NSRange(location: 0, length: 4), answered: nil)], [nil, hello])
    func aDictationIntoAnUnreadableFieldGoesInAsHeard(_ reason: Unreadable, after run: Commit.Run?) throws {
        let commit = try Self.dictating(" hello.", against: .unreadable(reason), after: run)
        #expect(commit == Commit(text: " hello.", replacementRange: Self.atTheSelection, placement: .unfitted(reason), run: nil))
    }

    /// A dictation replaces the selection, counted in characters as a person counts them, and
    /// leaves its words as the run ending where they do.
    @Test func aDictationCountsTheSelectionItReplaces() throws {
        let commit = try Self.dictating(" smile", against: Self.reading(before: "a ", selected: "🫠🫠"), after: nil)
        #expect(commit == Commit(text: "smile", replacementRange: Self.atTheSelection,
                                 placement: .fitted(Commit.Fitted(replaced: 2, before: .field, rules: [.trimmed])), run: Self.run("smile", endingAt: 7)))
    }

    /// Where the run ends, a field showing blanks over it, as iTerm2 does before the words are
    /// echoed, has the run's words stand before the caret: words continuing them are spaced from
    /// them, not capitalized, and join the run.
    @Test func aDictationWhereTheRunEndsIsFittedAfterItsWords() throws {
        let commit = try Self.dictating(" there", against: Self.reading(before: "Dear Sam." + Self.blanks(6)), after: Self.hello)
        #expect(commit == Commit(text: " there", replacementRange: Self.atTheSelection,
                                 placement: .fitted(Commit.Fitted(replaced: 0, before: .run(NSRange(location: 9, length: 6), blanks: 5),
                                                                  rules: [.trimmed, .spacedBefore])),
                                 run: Self.run(" Hello there", endingAt: 21)))
    }

    /// A field that shows some of the run as written and the rest blank, as a terminal echoing it
    /// does, still has the run stand, and says how many of its units read blank.
    @Test func aRunPartlyShownStillStands() throws {
        let commit = try Self.dictating(" there", against: Self.reading(before: "Dear Sam. He" + Self.blanks(3)), after: Self.hello)
        #expect(commit.text == " there")
        #expect(Self.source(commit) == .run(NSRange(location: 9, length: 6), blanks: 3))
    }

    /// The run's own sentence end still starts a sentence.
    @Test func aCapitalStillComesAfterTheRunsSentenceEnd() throws {
        let commit = try Self.dictating(" how are you", against: Self.reading(before: "Dear Sam." + Self.blanks(13)),
                                        after: Self.run(" Hello there.", endingAt: 22))
        #expect(commit.text == " How are you")
    }

    /// A commit that leaves nothing, a transcript of whitespace, continues the run, so the words
    /// after it are still fitted after the run's words.
    @Test func aCommitLeavingNothingKeepsTheRun() throws {
        let reading = Self.reading(before: "Dear Sam." + Self.blanks(6))
        let nothing = try Self.dictating(" ", against: reading, after: Self.hello)
        #expect(nothing.text == "")
        #expect(nothing.run == Self.hello)

        let commit = try Self.dictating(" there", against: reading, after: nothing.run)
        #expect(commit.text == " there")
        #expect(Self.source(commit) == .run(NSRange(location: 9, length: 6), blanks: 5))
    }

    /// A take-back that leaves nothing leaves no run, so the words after it are fitted to the field.
    @Test func aTakeBackLeavingNothingLeavesNoRun() throws {
        let takenBack = try Commit.decide(InsertRequest("", into: .app("com.example.editor"), replacing: "hello"),
                                          against: Self.reading(before: "say hello"), after: Self.run(" hello", endingAt: 9)).get()
        #expect(takenBack.run == nil)

        let commit = try Self.dictating(" there", against: Self.reading(before: "say "), after: takenBack.run)
        #expect(Self.source(commit) == .field)
    }

    /// Where the run ends but the field shows other text over it - an edit to the same length in a
    /// field that reads its text, or another field with its caret at the same place - the field's
    /// text stands, as it would with no run at all, and the event says the run was there.
    @Test(arguments: [("Dear Sam. Hello,", run(" Hello.", endingAt: 16)), ("Meeting notes for Sam, part", run(" Hello there.", endingAt: 27))])
    func aRunTheFieldShowsOtherTextOverIsNotFittedAfter(_ before: String, _ run: Commit.Run) throws {
        let commit = try Self.dictating(" two", against: Self.reading(before: before), after: run)
        let field = try Self.dictating(" two", against: Self.reading(before: before), after: nil)
        #expect(commit.text == " two")
        #expect(commit.text == field.text)
        #expect(Self.source(commit) == .fieldOverRun(run.range))
    }

    /// Anywhere but where the run ends, the field decides, as it reads.
    @Test(arguments: [14, 16])
    func aDictationAnywhereElseIsFittedToTheField(_ caret: Int) throws {
        let reading = Self.reading(before: "Dear Sam." + Self.blanks(caret - 9))
        let commit = try Self.dictating(" there", against: reading, after: Self.hello)
        #expect(commit == (try Self.dictating(" there", against: reading, after: nil)))
        #expect(commit.text == "There")
    }

    /// A run keeps as many of its last units as a read reaches back, in whole characters, and
    /// words that are nothing are no run.
    @Test func aRunKeepsTheUnitsAReadReaches() {
        let run = Self.run("🫠" + String(repeating: "a", count: FieldReading.bound - 1), endingAt: 2_000)
        #expect(run.words == String(repeating: "a", count: FieldReading.bound - 1))
        #expect(run.range == NSRange(location: 2_000 - (FieldReading.bound - 1), length: FieldReading.bound - 1))
        #expect(Commit.Run("", endingAt: 3) == nil)
    }

    /// What a take-back leaves is fitted to the text on both sides of the words it names.
    @Test func whatATakeBackLeavesIsFittedBetweenTheTextEitherSide() throws {
        let commit = try Commit.decide(InsertRequest("small.", into: .app("com.example.editor"), replacing: "big"),
                                       against: Self.reading(before: "a big", after: " dog"), after: nil).get()
        #expect(commit == Commit(text: "small", replacementRange: NSRange(location: 2, length: 3),
                                 placement: .fitted(Commit.Fitted(replaced: 3, before: .field, rules: [.periodDropped])),
                                 run: Self.run("small", endingAt: 7)))
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

    /// A take-back is proved against what the field reads, never the run: where the run ends, a
    /// field reading blanks there has no words to take back.
    @Test func aTakeBackWhereTheRunEndsIsProvedAgainstTheField() {
        let request = InsertRequest("", into: .app("com.example.editor"), replacing: "Hello")
        #expect(Commit.decide(request, against: Self.reading(before: "Dear Sam." + Self.blanks(6)), after: Self.hello) == .failure(.unfound(.differs)))
    }

    /// What the commit's event says: the rules in the order they apply, and where the text before
    /// the words came from.
    @Test func thePlacementSaysWhatFittingDid() {
        #expect(Commit.Fitted(replaced: 0, before: .field, rules: [.spacedAfter, .periodDropped, .capitalized, .spacedBefore, .trimmed])
            .description == "fitted: edge whitespace trimmed, closing period dropped, capitalized, space before, space after; the text before it from the field")
        #expect(Commit.Fitted(replaced: 0, before: .run(NSRange(location: 0, length: 3), blanks: 2), rules: []).description
            == "fitted, unchanged; the text before it from the input method's run, its 3 units at {0, 3}, 2 of them read blank")
        #expect(Commit.Fitted(replaced: 0, before: .fieldOverRun(NSRange(location: 0, length: 3)), rules: []).description
            == "fitted, unchanged; the text before it from the field, which reads other text over the input method's run, its 3 units at {0, 3}")
        #expect(Commit.Placement.unfitted(.noDocumentAccess).description == "unfitted, because it gives no document access")
    }
}
