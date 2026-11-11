import Foundation
import InputMethodFakes
import Testing

/// The fake answers as the clients were measured answering (`ContractCase.measured`), and as each
/// answer a client nobody measured could give is stated (`ContractCase.possible`), which is what
/// makes a suite built on it worth trusting.
@MainActor
@Suite struct TextInputClientContractTests {
    @Test(arguments: ContractCase.measured + ContractCase.possible)
    func theFakeAnswersAsTheCaseSays(_ statement: ContractCase) {
        let field = statement.fake()
        #expect(statement.disagreements(of: field, reading: { field.text }) == [])
    }

    /// Every profile is stated by a case, so none answers as nobody said it would.
    @Test(arguments: ClientProfile.all)
    func everyProfileIsStated(_ profile: ClientProfile) {
        #expect((ContractCase.measured + ContractCase.possible).contains { $0.profile == profile })
    }

    /// A case says when the client disagrees with it: a profile that answers wrongly turns its
    /// cases red.
    @Test func aClientAnsweringOtherwiseDisagrees() throws {
        let statement = try #require(ContractCase.measured.first { $0.profile.access == .none })
        let field = FakeTextInputClient(.appKit, holding: statement.holding, maxLength: statement.maxLength)

        #expect(!statement.disagreements(of: field, reading: { field.text }).isEmpty)
    }

    /// No selection-only client was measured taking an explicit range, so the fake fails the case
    /// that handed it one, and leaves the field as it was.
    @Test func anExplicitRangeIntoASelectionOnlyClientFailsTheCaseThatGaveIt() {
        let field = FakeTextInputClient(.iTerm2SelectionOnly, holding: "alpha")

        withKnownIssue { field.insertText("RNG", replacementRange: NSRange(location: 0, length: 3)) }
        #expect(field.text == "alpha")
    }

    /// Nobody said what a measured field keeps past its `maxlength`, so the fake fails the case
    /// that overflows one, and leaves the field as it was.
    @Test func anOverflowNobodyStatedFailsTheCaseThatGaveIt() {
        let field = FakeTextInputClient(.webKitInput, maxLength: 3)

        withKnownIssue { field.insertText("alpha", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(field.text.isEmpty)
    }

    /// A field answering all it was handed says the words it dropped are there, where a person
    /// sees none of them.
    @Test func aFieldAnsweringAllItWasHandedReadsTheWordsItDropped() {
        let field = FakeTextInputClient(.webKitLimitedTextAreaAnsweringAll, maxLength: 10)

        field.insertText("alpha bravo charlie delta echo", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.string(in: NSRange(location: 26, length: 4)) == "echo")
        #expect(field.text == "alpha brav")
    }

    /// Nobody said what a field answering words it dropped does with the next insert, so the fake
    /// fails the case that makes one, and leaves the field as it was.
    @Test func anInsertAfterAnsweringDroppedWordsFailsTheCaseThatGaveIt() {
        let field = FakeTextInputClient(.webKitLimitedTextAreaAnsweringAll, maxLength: 3)
        field.insertText("alpha", replacementRange: NSRange(location: NSNotFound, length: 0))

        withKnownIssue { field.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(field.text == "alp")
    }

    /// Nor what it does with a selection the person makes then, so the fake fails that case too,
    /// and the caret stays after what it answered.
    @Test func aSelectionAfterAnsweringDroppedWordsFailsTheCaseThatGaveIt() {
        let field = FakeTextInputClient(.webKitLimitedTextAreaAnsweringAll, maxLength: 3)
        field.insertText("alpha", replacementRange: NSRange(location: NSNotFound, length: 0))

        withKnownIssue { field.select(NSRange(location: 0, length: 0)) }
        #expect(field.selectedRange() == NSRange(location: 5, length: 0))
    }

    /// No client was measured answering a range past the end of its field, so the fake fails the
    /// one case that handed it such a range, and leaves the field as it was, rather than guess.
    @Test func aRangePastTheFieldFailsTheCaseThatGaveIt() {
        let field = FakeTextInputClient(holding: "alpha")

        withKnownIssue { field.insertText("RNG", replacementRange: NSRange(location: 20, length: 3)) }
        #expect(field.text == "alpha")
    }
}
