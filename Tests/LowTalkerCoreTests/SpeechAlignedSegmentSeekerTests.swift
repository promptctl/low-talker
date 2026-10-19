import CoreML
@testable import LowTalkerCore
import Testing
import WhisperKit

/// The rows and columns the seeker aligns over, exercised on hand-built tensors run
/// through WhisperKit's own aligner; the seeker over a real decode is exercised by
/// the bench with `--vocabulary`, which is where the timings were lost, and by serve.
@Suite struct SpeechAlignedSegmentSeekerTests {
    static let specialTokenBegin = 50257

    /// No prompt takes no rows; a prompt takes one for `<|startofprev|>` and one
    /// per token WhisperKit keeps, which is none of the special ones.
    @Test func thePromptRowsAreStartOfPrevAndTheKeptTokens() {
        #expect(SpeechAlignedSegmentSeeker.promptRows(before: nil, specialTokenBegin: Self.specialTokenBegin) == 0)
        #expect(SpeechAlignedSegmentSeeker.promptRows(before: [], specialTokenBegin: Self.specialTokenBegin) == 0)
        #expect(SpeechAlignedSegmentSeeker.promptRows(before: [12812, 77, 45533], specialTokenBegin: Self.specialTokenBegin) == 4)
        #expect(SpeechAlignedSegmentSeeker.promptRows(before: [50362, 12812, 77], specialTokenBegin: Self.specialTokenBegin) == 3)
        #expect(SpeechAlignedSegmentSeeker.promptRows(before: [50362], specialTokenBegin: Self.specialTokenBegin) == 0)
    }

    /// A prompt past the limit keeps its last `promptTokenLimit` tokens, as
    /// WhisperKit's decoder prefills it.
    @Test func aLongPromptIsCountedByWhatWhisperKitKeeps() {
        let limit = SpeechAlignedSegmentSeeker.promptTokenLimit
        let long = Array(0..<(limit + 40))
        #expect(SpeechAlignedSegmentSeeker.promptRows(before: long, specialTokenBegin: Self.specialTokenBegin) == limit + 1)
    }

    /// The alignment is the rows asked for over their leading columns, each element the
    /// one it was in the model's padded rows, run out to the width of WhisperKit's copy
    /// with columns closed to every row but the last; and WhisperKit's copy of it is no
    /// wider.
    @Test(arguments: [0, 1, 3])
    func theAlignmentIsTheRowsOverTheAudioAsWideAsWhisperKitsCopy(first: Int) throws {
        let array = try MLMultiArray(shape: [5, 40], dataType: .float16, initialValue: FloatType(0))
        #expect(array.strides[0].intValue > 40)
        for row in 0..<5 {
            for column in 0..<40 {
                array[[row, column] as [NSNumber]] = NSNumber(value: Float(row * 100 + column))
            }
        }
        let alignment = try array.speechAlignment(rows: first..<(first + 2), columns: 25)
        let width = alignment.shape[1].intValue
        #expect(alignment.shape[0].intValue == 2 && width >= 25)
        #expect(try MLMultiArray(shape: alignment.shape, dataType: .float16, initialValue: FloatType(0)).strides[0].intValue == width)
        for column in 0..<width {
            for row in 0..<2 {
                let cell = alignment[[row, column] as [NSNumber]].floatValue
                #expect(cell == (column < 25 ? Float((first + row) * 100 + column) : row == 1 ? 0 : -65_504))
            }
        }
    }

    /// Rows or columns the array does not have are refused, not read past its end.
    @Test func anAlignmentPastTheArrayIsRefused() throws {
        let array = try MLMultiArray(shape: [2, 3], dataType: .float16)
        #expect(throws: WhisperError.self) { try array.speechAlignment(rows: 0..<2, columns: 4) }
        #expect(throws: WhisperError.self) { try array.speechAlignment(rows: 1..<3, columns: 3) }
    }

    /// A window's speech is counted in whole frames from its seek to the speech's end,
    /// and never less than the one frame the speech starts in.
    @Test func theSpeechColumnsAreTheWholeFramesOfSpeechInTheWindow() {
        let seeker = SpeechAlignedSegmentSeeker(arrived: 48_000)
        #expect(seeker.speechColumns(seek: 0, segmentSize: 48_000) == 150)
        #expect(seeker.speechColumns(seek: 16_000, segmentSize: 32_000) == 100)
        #expect(SpeechAlignedSegmentSeeker(arrived: 8_000).speechColumns(seek: 0, segmentSize: 16_001) == 25)
        #expect(SpeechAlignedSegmentSeeker(arrived: 8_319).speechColumns(seek: 0, segmentSize: 16_001) == 25)
        #expect(SpeechAlignedSegmentSeeker(arrived: 100).speechColumns(seek: 0, segmentSize: 16_001) == 1)
    }

    /// The noise case (low-serve-nac): 3 s of noise read as words whose attention lies in
    /// the padding near 29 s. WhisperKit's own seeker times them there; this one times
    /// every word within the 3 s of audio.
    @Test func wordsReadIntoThePaddingAreTimedWithinTheSpeech() throws {
        let attention = try Self.attention(spans: [1_450, 1_453, 1_456, 1_460, 1_462])
        let padded = try Self.words(SegmentSeeker(), attention: attention, segmentSize: 48_000)
        #expect(padded.contains { $0.end > 3 })
        let words = try Self.words(SpeechAlignedSegmentSeeker(arrived: 48_000), attention: attention, segmentSize: 48_000)
        #expect(words.count == 3)
        #expect(words.allSatisfy { 0 <= $0.start && $0.start <= $0.end && $0.end <= 3 })
    }

    /// Silence `Pipeline.window` ran a short utterance out with is no more speech than
    /// the encoder's own padding: half a second of speech handed over as a second is
    /// timed within the half second.
    @Test func wordsAreTimedWithinTheSpeechNotTheSilenceItWasRunOutWith() throws {
        let attention = try Self.attention(spans: [0, 10, 20, 40, 50])
        let padded = try Self.words(SegmentSeeker(), attention: attention, segmentSize: 16_001)
        #expect(padded.contains { $0.end > 0.5 })
        let words = try Self.words(SpeechAlignedSegmentSeeker(arrived: 8_000), attention: attention, segmentSize: 16_001)
        #expect(words.count == 3)
        #expect(words.allSatisfy { $0.start <= $0.end && $0.end <= 0.5 })
    }

    /// Words the audio holds are timed by their attention, each entered a frame before
    /// its span as the warping steps down a row, as WhisperKit's own seeker times them.
    @Test func wordsInTheAudioAreTimedAsWhisperKitTimesThem() throws {
        let attention = try Self.attention(spans: [0, 25, 50, 75, 150])
        let words = try Self.words(SpeechAlignedSegmentSeeker(arrived: 48_000), attention: attention, segmentSize: 48_000)
        let theirs = try Self.words(SegmentSeeker(), attention: attention, segmentSize: 48_000)
        #expect(words.map(\.start) == [0, 0.48, 0.98])
        #expect(words.map(\.end) == [0.48, 0.98, 1.48])
        #expect(words.map(\.start) == theirs.map(\.start) && words.map(\.end) == theirs.map(\.end))
    }

    /// Whisper's boundary heuristic lengthens a last word shorter than the median to the
    /// median: over 3.5 s of speech, to 3.1 s. Over 3 s, the same word ends at the last
    /// frame of the speech.
    @Test func aLastWordLengthenedPastTheSpeechEndsAtItsLastFrame() throws {
        let attention = try Self.attention(spans: [0, 33, 121, 149, 150])
        let words = try Self.words(SpeechAlignedSegmentSeeker(arrived: 48_000), attention: attention, segmentSize: 48_000, segmentEnd: 2.45)
        let longer = try Self.words(SpeechAlignedSegmentSeeker(arrived: 56_000), attention: attention, segmentSize: 56_000, segmentEnd: 2.45)
        #expect(try #require(longer.last).end > 3)
        #expect(words.map(\.start) == [0, 0.64, 2.4])
        #expect(words.map(\.end) == [0.64, 2.4, 2.98])
    }

    // MARK: - WhisperKit's aligner over a hand-built window

    /// One token per word, " w<id>", and every token from `specialTokenBegin` on special.
    struct Tokenizer: WhisperTokenizer {
        let specialTokens = SpecialTokens(
            endToken: 50257, englishToken: 50259, noSpeechToken: 50363, noTimestampsToken: 50364,
            specialTokenBegin: 50257, startOfPreviousToken: 50362, startOfTranscriptToken: 50258,
            timeTokenBegin: 50365, transcribeToken: 50360, translateToken: 50359, whitespaceToken: 220
        )
        let allLanguageTokens: Set<Int> = []
        func encode(text: String) -> [Int] { [] }
        func decode(tokens: [Int]) -> String { tokens.map { " w\($0)" }.joined() }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
            (tokenIds.map { decode(tokens: [$0]) }, tokenIds.map { [$0] })
        }
    }

    /// A window's cross-attention as the model hands it over, half precision in a pixel
    /// buffer's padded rows: one row a token, the whole of it over the columns from one
    /// bound in `spans` to the next.
    static func attention(spans: [Int]) throws -> MLMultiArray {
        let attention = try MLMultiArray(shape: [spans.count - 1, 1_500] as [NSNumber], dataType: .float16, initialValue: FloatType(0))
        for (row, span) in zip(spans, spans.dropFirst()).enumerated() {
            for column in span.0..<span.1 { attention[[row, column] as [NSNumber]] = 1 }
        }
        return attention
    }

    /// The words `seeker` times for a segment of three words and its end token, one row each.
    static func words(_ seeker: some SegmentSeeking, attention: MLMultiArray, segmentSize: Int, segmentEnd: Float = 0) throws -> [WordTiming] {
        let tokens = [1, 2, 3, 50257]
        let segment = TranscriptionSegment(end: segmentEnd, tokens: tokens, tokenLogProbs: tokens.map { [$0: -0.1] })
        let timed = try seeker.addWordTimestamps(
            segments: [segment], alignmentWeights: attention, tokenizer: Tokenizer(), seek: 0, segmentSize: segmentSize,
            prependPunctuations: Constants.defaultPrependPunctuations, appendPunctuations: Constants.defaultAppendPunctuations,
            lastSpeechTimestamp: 0, options: DecodingOptions(), timings: TranscriptionTimings()
        )
        return try #require(timed?.first?.words)
    }
}
