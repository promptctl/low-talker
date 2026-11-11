import Foundation
import InputMethodFakes
import Testing

/// The fake answers as the clients were measured answering (`ContractCase.measured`), and as its
/// guesses for studious to settle say (`ContractCase.unsettled`), which is what makes a suite
/// built on it worth trusting. The same cases run against real clients on studious
/// (low-test-layers-sqm.8m3); a case a real client fails there is the fake to change.
@MainActor
@Suite struct TextInputClientContractTests {
    @Test(arguments: ContractCase.measured + ContractCase.unsettled)
    func theFakeAnswersAsTheCaseSays(_ statement: ContractCase) {
        let field = statement.fake()
        #expect(statement.disagreements(of: field, holds: { field.text }) == [])
    }

    /// A case says when the client disagrees with it, which is the whole of what the studious run
    /// reads: a profile that answers wrongly turns its cases red.
    @Test func aClientAnsweringOtherwiseDisagrees() throws {
        let statement = try #require(ContractCase.measured.first { $0.profile.access == .none })
        let field = FakeTextInputClient(.appKit, holding: statement.holding, maxLength: statement.maxLength)

        #expect(!statement.disagreements(of: field, holds: { field.text }).isEmpty)
    }
}
