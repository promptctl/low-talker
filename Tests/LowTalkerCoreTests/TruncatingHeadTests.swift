import LowTalkerCore
import Testing

/// Truncation at the head keeps the newest words that fit, measured here in characters where
/// the panel measures in lines.
@Suite struct TruncatingHeadTests {
    static let transcript = Transcript(typed: " one two three four")

    private func truncated(_ transcript: Transcript = Self.transcript, to characters: Int) -> String {
        transcript.truncatingHead { $0.count <= characters }
    }

    /// Text that fits is shown whole, less the space the engine put before its first word.
    @Test func textThatFitsIsShownWhole() {
        #expect(truncated(to: 18) == "one two three four")
    }

    /// Only as many of the oldest words go as must for the rest to fit.
    @Test func dropsTheFewestOldestWords() {
        #expect(truncated(to: 17) == "…two three four")
        #expect(truncated(to: 15) == "…two three four")
        #expect(truncated(to: 14) == "…three four")
        #expect(truncated(to: 10) == "…four")
    }

    /// A line is the words without the whitespace before the first, and none of the rest dropped.
    @Test func aLineDropsOnlyTheWhitespaceBeforeTheFirstWord() {
        #expect(Self.transcript.line == "one two three four")
        #expect(Transcript(typed: "\n\t two  three").line == "two  three")
        #expect(Transcript(words: []).line == "")
    }

    /// The newest word is shown even where it fits nowhere.
    @Test func keepsTheNewestWordWhenNothingFits() {
        #expect(truncated(to: 0) == "…four")
        #expect(truncated(Transcript(typed: " solitary"), to: 0) == "solitary")
        #expect(truncated(Transcript(words: []), to: 0) == "")
    }
}
