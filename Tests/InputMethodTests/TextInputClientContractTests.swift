import Foundation
import InputMethodFakes
import Testing

/// The fake answers as the clients were measured answering (`ContractCase.measured`), and as its
/// guesses where none was say (`ContractCase.unsettled`), which is what makes a suite built on it
/// worth trusting.
@MainActor
@Suite struct TextInputClientContractTests {
    @Test(arguments: ContractCase.measured + ContractCase.unsettled)
    func theFakeAnswersAsTheCaseSays(_ statement: ContractCase) {
        let field = statement.fake()
        #expect(statement.disagreements(of: field) == [])
    }

    /// A case says when the client disagrees with it: a profile that answers wrongly turns its
    /// cases red.
    @Test func aClientAnsweringOtherwiseDisagrees() throws {
        let statement = try #require(ContractCase.measured.first { $0.profile.access == .none })
        let field = FakeTextInputClient(.appKit, holding: statement.holding, maxLength: statement.maxLength)

        #expect(!statement.disagreements(of: field).isEmpty)
    }

    /// No client was measured answering a range past the end of its field, so the fake fails the
    /// one case that handed it such a range, and leaves the field as it was, rather than guess.
    @Test func aRangePastTheFieldFailsTheCaseThatGaveIt() {
        let field = FakeTextInputClient(holding: "alpha")

        withKnownIssue { field.insertText("RNG", replacementRange: NSRange(location: 20, length: 3)) }
        #expect(field.text == "alpha")
    }
}
