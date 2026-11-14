import InputSource
import InputSourceFakes
import Testing

/// The input method installation's contract, on the fake.
@MainActor @Suite struct InputMethodInstallationContractTests {
    static let fake = InputMethodInstallationContract { FakeInputMethodInstallation(switchedOn: $0) }

    @Test(arguments: InputMethodInstallationContract.Statement.allCases)
    func theFakeKeepsTheContract(_ statement: InputMethodInstallationContract.Statement) async throws {
        #expect(try await Self.fake.disagreements(with: statement) == [])
    }
}
