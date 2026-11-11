import GrammaticalNumber
import Testing

/// A count is told with what it counts in the number the count takes.
@Suite struct CountedTests {
    @Test(arguments: [(0, "0 words are held"), (1, "1 word is held"), (2, "2 words are held")])
    func aCountTakesTheNumberItsCountSays(_ count: Int, _ told: String) {
        #expect(counted(count, "word is held", "words are held") == told)
    }
}
