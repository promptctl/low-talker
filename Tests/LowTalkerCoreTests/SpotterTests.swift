import Foundation
@testable import LowTalkerCore
import Testing

/// What the real models made of `bench/say/names.wav` ("Ask Brynleigh Fryslie to review the pull
/// request before Jaxxon merges it."), captured once, so the spotter is held to real model output
/// with no model run: the spotter's CTC log-probabilities, one Float16 row of 1,025 per 80 ms
/// frame, and what bare Parakeet heard, as its transcript. With them, the tokenizer of
/// FluidInference/parakeet-ctc-110m-coreml at accdafd8, which spells the terms as the model reads
/// them. Captured 2026-11-14 from a dictation over the real models: the frames `ParakeetReader.spot`
/// built for the pass over the whole clip, past its speech by the engine's hangover.
enum Captured {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/spotter"))
    }

    static var tokenizer: SpotterTokenizer {
        get throws { try SpotterTokenizer(json: Data(contentsOf: url("tokenizer.json"))) }
    }

    static var frames: [[Float]] {
        get throws {
            let data = try Data(contentsOf: url("names.ctc.f16"))
            let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map { Float($0) }
            return stride(from: 0, to: values.count, by: SpotterClasses.count).map { Array(values[$0..<$0 + SpotterClasses.count]) }
        }
    }

    /// Bare Parakeet's words, timed in samples as a pass times them.
    static var heard: [HeardWord] {
        get throws {
            let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url("names-bare.json")))
            return transcript.words.map { word in
                HeardWord(text: word.text, first: AudioClip.sampleCount(for: word.time.lowerBound), last: AudioClip.sampleCount(for: word.time.upperBound) - ParakeetWindow.frameSamples, confidence: word.confidence)
            }
        }
    }

    static func spotter(_ terms: [String]) throws -> CTCWordSpotter {
        let tokenizer = try tokenizer
        return CTCWordSpotter(terms: try tokenizer.terms(Vocabulary(terms.map { try Vocabulary.Term($0) })), blank: SpotterClasses.blank, wordStarts: tokenizer.wordStarts)
    }

    static func text(_ words: [HeardWord]) -> String {
        words.map(\.text).joined()
    }
}

@Suite struct CapturedNamesTests {
    /// The ticket's done-when, on real model output: bare Parakeet misspells the names, and told
    /// them it spells Brynleigh and Jaxxon as the vocabulary does.
    @Test func theNamesAreSpelledAsTheVocabularySays() throws {
        let heard = try Captured.heard
        #expect(Captured.text(heard) == " Ask Bryan Leigh Frisley to review the pull request before Jackson merges it.")
        let spotting = try Captured.spotter(["Brynleigh", "Fryslie", "Jaxxon"]).spot(Captured.frames)
        let spotted = try spotting.hits.map { try $0.spotted(from: 0) }
        #expect(Captured.text(HeardWord.merging(spotted, into: heard)) == " Ask Brynleigh Frisley to review the pull request before Jaxxon merges it.")
    }

    /// Fryslie is found, and refused: the model hears "▁F r is le ly" there, sure of `is` where
    /// every spelling of Fryslie has `y`, so the greedy reading of those frames outscores it.
    @Test func aTermSpelledFarFromTheSpeechIsOutscored() throws {
        let spotting = try Captured.spotter(["Fryslie"]).spot(Captured.frames)
        #expect(spotting.hits.isEmpty)
        #expect(spotting.outscored == 1)
    }
}

extension CapturedNamesTests {
    /// Terms the clip does not say are not heard in it: the greedy reading outscores wherever the
    /// search ends on them, and the words stand as bare Parakeet heard them.
    @Test func termsTheClipDoesNotSayAreNotHeard() throws {
        let spotting = try Captured.spotter(["Kubernetes", "Anthropic", "Jackie"]).spot(Captured.frames)
        #expect(spotting.hits.isEmpty)
        let heard = try Captured.heard
        #expect(Captured.text(HeardWord.merging(try spotting.hits.map { try $0.spotted(from: 0) }, into: heard)) == Captured.text(heard))
    }
}

/// A vocabulary of pieces a test can read, laid out as tokenizer.json lays one out.
func tokenizer(_ pieces: [String]) throws -> SpotterTokenizer {
    let vocab = Dictionary(uniqueKeysWithValues: pieces.enumerated().map { ($1, $0) })
    return try SpotterTokenizer(json: JSONEncoder().encode(["model": ["vocab": vocab]]))
}

@Suite struct SpotterTokenizerTests {
    static let pieces = ["▁F", "▁Fr", "r", "y", "ry", "s", "le", "l", "ie", "e", "i", "▁N", "ew", "▁Y", "ork"]

    /// Every sequence of pieces that writes the term is a spelling of it: from each position, the
    /// pieces that start there, a word's first piece led by `▁`.
    @Test func aTermIsEverySequenceOfPiecesThatWritesIt() throws {
        let tokenizer = try tokenizer(Self.pieces)
        let spelled = try tokenizer.spell(Vocabulary.Term("Frylie"))
        func spellings(from position: Int) -> [[String]] {
            position == spelled.end ? [[]] : spelled.arcs[position].flatMap { arc in spellings(from: arc.to).map { [Self.pieces[arc.id]] + $0 } }
        }
        #expect(Set(spellings(from: 0)) == [["▁F", "ry", "l", "ie"], ["▁F", "ry", "l", "i", "e"], ["▁F", "r", "y", "l", "ie"], ["▁F", "r", "y", "l", "i", "e"], ["▁Fr", "y", "l", "ie"], ["▁Fr", "y", "l", "i", "e"]])
        #expect(spelled.arcs[0].allSatisfy { $0.startsWord })
        #expect(spelled.arcs.dropFirst().joined().allSatisfy { !$0.startsWord })
    }

    /// A term of two words is spelled whole, its second word from a `▁` piece of its own, and no
    /// piece spans the space between.
    @Test func aTermOfTwoWordsStartsEachWithItsOwnPiece() throws {
        let spelled = try tokenizer(Self.pieces).spell(Vocabulary.Term("New York"))
        #expect(spelled.arcs.joined().filter(\.startsWord).map { Self.pieces[$0.id] } == ["▁N", "▁Y"])
        #expect(spelled.words == ["New", "York"])
    }

    /// A term the pieces cannot write is refused, naming the first character they stop at.
    @Test func aTermThePiecesCannotWriteIsRefused() throws {
        let tokenizer = try tokenizer(Self.pieces)
        #expect(throws: VocabularyError.unspellable(term: "Fryxie", piece: "x")) { try tokenizer.spell(Vocabulary.Term("Fryxie")) }
        #expect(throws: VocabularyError.unspellable(term: "fry", piece: "f")) { try tokenizer.spell(Vocabulary.Term("fry")) }
    }

    /// A tokenizer.json with no pieces, or a piece no class of the head's rows reads, is
    /// refused as it is read, not when a term is spelled.
    @Test func aTokenizerTheHeadCannotReadIsRefused() throws {
        #expect(throws: PromptsUnavailable(why: "the spotter's tokenizer.json has no pieces")) { try tokenizer([]) }
        let past = try JSONEncoder().encode(["model": ["vocab": ["▁Zed": SpotterClasses.blank]]])
        #expect(throws: PromptsUnavailable(why: "the spotter's tokenizer.json gives ▁Zed id 1024, outside the head's 1024 pieces")) { try SpotterTokenizer(json: past) }
    }

    /// The spotter's real vocabulary spells the bench's names and refuses what it has no piece
    /// for, by the character.
    @Test func theRealVocabularySpellsNamesAndRefusesTheRest() throws {
        let tokenizer = try Captured.tokenizer
        _ = try tokenizer.terms(Vocabulary(["Brynleigh", "Fryslie", "Jaxxon", "O'Brien", "Low Talker"].map { try Vocabulary.Term($0) }))
        #expect(throws: VocabularyError.unspellable(term: "Zoë", piece: "ë")) { try tokenizer.spell(Vocabulary.Term("Zoë")) }
        #expect(throws: VocabularyError.unspellable(term: "K8s", piece: "8")) { try tokenizer.spell(Vocabulary.Term("K8s")) }
    }
}

@Suite struct CTCWordSpotterTests {
    /// Classes 0-3 are `▁Zed`, `▁Ze`, `d`, `▁Q`; class 4 the blank.
    static let pieces = ["▁Zed", "▁Ze", "d", "▁Q"]
    static let blank = 4

    /// Frames from a script: each one the class it names, likely, and the rest far less so.
    static func frames(_ classes: [Int], sure: Float = 0.9) -> [[Float]] {
        classes.map { said in (0...blank).map { $0 == said ? Foundation.log(sure) : Foundation.log((1 - sure) / Float(blank)) } }
    }

    static func spotter(_ terms: [String], pieces: [String] = Self.pieces) throws -> CTCWordSpotter {
        let tokenizer = try tokenizer(pieces)
        return CTCWordSpotter(terms: try tokenizer.terms(Vocabulary(terms.map { try Vocabulary.Term($0) })), blank: Self.blank, wordStarts: tokenizer.wordStarts)
    }

    /// A term is found across the frames its pieces sound on, held or parted by blanks, in
    /// whichever of its spellings the frames hold, with the frame each piece was entered on.
    @Test func aTermIsFoundWhereItsPiecesSound() throws {
        let spotting = try Self.spotter(["Zed"]).spot(Self.frames([4, 1, 1, 4, 2, 4]))
        let hit = try #require(spotting.hits.first)
        #expect(spotting.hits.count == 1)
        #expect(hit.path.map(\.arc.id) == [1, 2])
        #expect(hit.path.map(\.frame) == [1, 4])
        #expect(hit.end == 4)
    }

    /// A piece that repeats the last needs a blank between, as CTC reads two frames of one piece as
    /// one: `Zedd` is not heard as `▁Ze d d` in a `d` held, and is heard with a blank parting them.
    @Test func aRepeatedPieceNeedsABlankBetween() throws {
        let spotter = try Self.spotter(["Zedd"])
        #expect(spotter.spot(Self.frames([1, 2, 2], sure: 0.999)).hits.isEmpty)
        #expect(spotter.spot(Self.frames([1, 2, 4, 2], sure: 0.999)).hits.first?.path.map(\.arc.id) == [1, 2, 2])
    }

    /// No term starts on a frame that is surely blank, nor on a piece the frame all but rules out.
    @Test func noTermStartsWhereTheFrameRulesItOut() throws {
        #expect(try Self.spotter(["Zed"]).spot(Self.frames([4, 4, 4])).candidates == 0)
    }

    /// Where the greedy reading of the same frames scores above the term, the term is found and
    /// refused: `▁Q` sounds there, sure, and `▁Zed` only faintly.
    @Test func aTermTheGreedyReadingOutscoresIsRefused() throws {
        var frames = Self.frames([3, 3, 3], sure: 0.97)
        for index in frames.indices { frames[index][0] = Foundation.log(0.02) }
        let spotting = try Self.spotter(["Zed"]).spot(frames)
        #expect(spotting.hits.isEmpty)
        // Found starting on each frame, a `▁Zed` apart from the others, and each refused.
        #expect(spotting.candidates >= 3)
        #expect(spotting.outscored == 3)
    }

    /// Of two terms found over the same frames, the better scoring is kept.
    @Test func ofOverlappingTermsTheBetterIsKept() throws {
        let spotting = try Self.spotter(["Zed", "Ze"]).spot(Self.frames([1, 1, 2]))
        #expect(spotting.hits.map(\.term.term.text) == ["Zed"])
    }

    /// A term's words are each timed from the frame its first piece was entered on to the frame
    /// its last was, in samples from where the frames start, as sure as its pieces were there,
    /// and the term runs on over the frames its last piece was held.
    @Test func aTermsWordsAreTimedByTheirPieces() throws {
        let pieces = ["▁Ze", "d", "▁Q", "▁Zed"]
        let spotting = try Self.spotter(["Zed Q"], pieces: pieces).spot(Self.frames([0, 0, 1, 4, 2, 2], sure: 0.9))
        let spotted = try #require(spotting.hits.first).spotted(from: 1_000)
        let words = spotted.words
        #expect(words.map(\.text) == [" Zed", " Q"])
        #expect(words.map(\.first) == [1_000, 1_000 + 4 * ParakeetWindow.frameSamples])
        #expect(words.map(\.last) == [1_000 + 2 * ParakeetWindow.frameSamples, 1_000 + 4 * ParakeetWindow.frameSamples])
        #expect(spotted.last == 1_000 + 5 * ParakeetWindow.frameSamples)
        #expect(abs(words[0].confidence.value - 0.81) < 0.001)
    }
}

@Suite struct HeardWordMergingTests {
    static func word(_ text: String, _ first: Int, _ last: Int) -> HeardWord {
        HeardWord(text: text, first: first * ParakeetWindow.frameSamples, last: last * ParakeetWindow.frameSamples, confidence: 0.5)
    }

    static func term(_ text: String, _ first: Int, _ last: Int) -> SpottedTerm {
        SpottedTerm(words: [word(text, first, last)], last: last * ParakeetWindow.frameSamples)
    }

    /// A term takes the place of the words whose midpoints fall within it, keeping the last one's
    /// punctuation, and leaves a word beside it whose midpoint is outside it.
    @Test func aTermReplacesTheWordsSoundingWithinIt() {
        let heard = [Self.word(" Ask", 0, 1), Self.word(" Bryan", 3, 5), Self.word(" Lee,", 6, 7), Self.word(" to", 9, 9)]
        let merged = HeardWord.merging([Self.term(" Brynleigh", 3, 8)], into: heard)
        #expect(merged.map(\.text) == [" Ask", " Brynleigh,", " to"])
    }

    /// A term replaces a word heard over the frames its last piece was held, not only the frame
    /// the piece was entered on: one piece held is not heard beside the word it corrects.
    @Test func aTermHeldOverFramesReplacesTheWordHeardThere() {
        let held = SpottedTerm(words: [Self.word(" Jaxxon", 10, 10)], last: 13 * ParakeetWindow.frameSamples)
        let merged = HeardWord.merging([held], into: [Self.word(" Jackson", 10, 13), Self.word(" merges", 15, 16)])
        #expect(merged.map(\.text) == [" Jaxxon", " merges"])
    }

    /// A term across the cut keeps the words sounding after it, as the TDT words are cut.
    @Test func aTermIsCutWordByWord() {
        let term = SpottedTerm(words: [Self.word(" Brynleigh", 2, 3), Self.word(" Fryslie", 6, 7)], last: 7 * ParakeetWindow.frameSamples)
        #expect(term.sounding(after: 5 * ParakeetWindow.frameSamples)?.words.map(\.text) == [" Fryslie"])
        #expect(term.sounding(after: 9 * ParakeetWindow.frameSamples) == nil)
    }

    /// Punctuation a term spells is not added again from the word it replaces; only what the
    /// word carries past it is.
    @Test func aTermsOwnPunctuationIsNotDoubled() {
        let merged = HeardWord.merging([Self.term(" Yahoo!", 1, 2), Self.term(" Inc.", 5, 6)], into: [Self.word(" Yahoo!", 1, 2), Self.word(" Inc.,", 5, 6)])
        #expect(merged.map(\.text) == [" Yahoo!", " Inc.,"])
    }

    /// A term over frames where no word was heard takes its place among them by time.
    @Test func aTermWhereNoWordWasHeardIsPlacedByTime() {
        let merged = HeardWord.merging([Self.term(" Zed", 4, 5)], into: [Self.word(" one", 0, 1), Self.word(" two", 8, 9)])
        #expect(merged.map(\.text) == [" one", " Zed", " two"])
    }

    /// A word is placed by its midpoint: the cut and the merge both read it from the same rule.
    @Test func aWordIsPlacedByItsMidpoint() {
        let word = Self.word(" two", 4, 6)
        #expect(HeardWord.sounds(from: word.first, to: word.last, after: 5 * ParakeetWindow.frameSamples))
        #expect(!HeardWord.sounds(from: word.first, to: word.last, after: 6 * ParakeetWindow.frameSamples))
        #expect(word.sounds(within: 4 * ParakeetWindow.frameSamples, 5 * ParakeetWindow.frameSamples))
        #expect(!word.sounds(within: 6 * ParakeetWindow.frameSamples, 8 * ParakeetWindow.frameSamples))
    }
}
