import Insertion
import Testing

/// What an insert the app has not taken yet tells the person agrees with how much it handed.
@Suite struct NotYetTakenTests {
    @Test(arguments: [
        (1, "The 1 character lands if it recovers; do not dictate it again."),
        (2, "The 2 characters land if it recovers; do not dictate them again."),
    ])
    func itsFateAgreesWithItsCount(_ characters: Int, _ fate: String) {
        #expect(NotYetTaken(characters: characters, into: "com.apple.TextEdit").fate == fate)
    }
}
