import CoreML
import Identity
import os
import WhisperKit

/// WhisperKit's segment seeker, aligning the transcript's tokens against the speech
/// alone: the cross-attention rows from where the transcript's tokens begin once a
/// prompt stands before them, and the columns from the window's start to the end of
/// the speech in it.
///
/// Rows: WhisperKit 1.1.0 writes the alignment row of every decoder step at the step's
/// index in the whole prefilled sequence, and a prompt goes at the front of that
/// sequence as `<|startofprev|>` and the prompt's tokens (TextDecoder.
/// prepareDecoderInputs). The tokens it aligns are cut from `<|startoftranscript|>`
/// (decodeText) and their rows are read by their index in that cut
/// (SegmentSeeker.addWordTimestamps), so with a prompt of P tokens every word is
/// read P+1 rows early and short windows lose every word.
///
/// Columns: WhisperKit runs its dynamic time warping over all 1500 columns of the
/// 30 s window, the silence the encoder pads it with included, where Whisper's
/// reference aligner (timing.py, find_alignment) keeps only the frames of the audio.
/// On noise the decoder reads words no audio holds, and the warping placed them in
/// the padding: 3 s of noise answered a segment at 29.1 s. The silence an `Utterance`
/// stands in for its hangover with, and `Pipeline.window` runs a short utterance out
/// with, is padding too, so the columns end where the audio that arrived does, not where
/// the window WhisperKit was handed does, and its aligner is handed them as it reads
/// them (`speechAlignment(rows:columns:)`).
///
/// [LAW:one-source-of-truth] The prompt's rows are counted by the rule the text
/// decoder prefills with: the prompt's last `promptTokenLimit` tokens with special
/// tokens dropped, and `<|startofprev|>` before them when any are left. Exception:
/// the rule is restated here because WhisperKit does not expose it, and it is
/// restated once, so the transcriber's refusal of a long prompt derives from here.
struct SpeechAlignedSegmentSeeker: SegmentSeeking {
    private let seeker = SegmentSeeker()
    /// How many samples of the audio WhisperKit is handed arrived as audio, counted as
    /// WhisperKit counts `seek`; the rest is silence run out past them.
    let arrived: Int

    /// The most prompt tokens WhisperKit prefills; a longer prompt keeps its last
    /// this many.
    static let promptTokenLimit = Constants.maxTokenContext / 2 - 1

    /// The samples one alignment column spans: one encoder frame, which is one time token.
    static let samplesPerColumn = Int((Float(WhisperKit.sampleRate) * WhisperKit.secondsPerTimeToken).rounded())

    static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "alignment")

    /// How many rows the prompt took before the transcript's first row: none for
    /// no prompt, else `<|startofprev|>` and the tokens WhisperKit kept of it.
    static func promptRows(before promptTokens: [Int]?, specialTokenBegin: Int) -> Int {
        let kept = (promptTokens ?? []).suffix(promptTokenLimit).filter { $0 < specialTokenBegin }
        return kept.isEmpty ? 0 : kept.count + 1
    }

    /// How many columns of the window at `seek`, `segmentSize` samples long, hold audio
    /// that arrived: whole frames only, as Whisper counts them, and at least the frame
    /// the audio starts in, since the warping needs a column to place a token in.
    func speechColumns(seek: Int, segmentSize: Int) -> Int {
        max(1, (min(seek + segmentSize, arrived) - seek) / Self.samplesPerColumn)
    }

    func findSeekPointAndSegments(
        decodingResult: DecodingResult,
        options: DecodingOptions,
        allSegmentsCount: Int,
        currentSeek seek: Int,
        segmentSize: Int,
        sampleRate: Int,
        timeToken: Int,
        specialToken: Int,
        tokenizer: WhisperTokenizer
    ) -> (Int, [TranscriptionSegment]?) {
        seeker.findSeekPointAndSegments(
            decodingResult: decodingResult,
            options: options,
            allSegmentsCount: allSegmentsCount,
            currentSeek: seek,
            segmentSize: segmentSize,
            sampleRate: sampleRate,
            timeToken: timeToken,
            specialToken: specialToken,
            tokenizer: tokenizer
        )
    }

    func addWordTimestamps(
        segments: [TranscriptionSegment],
        alignmentWeights: MLMultiArray,
        tokenizer: WhisperTokenizer,
        seek: Int,
        segmentSize: Int,
        prependPunctuations: String,
        appendPunctuations: String,
        lastSpeechTimestamp: Float,
        options: DecodingOptions,
        timings: TranscriptionTimings
    ) throws -> [TranscriptionSegment]? {
        let promptRows = Self.promptRows(before: options.promptTokens, specialTokenBegin: tokenizer.specialTokens.specialTokenBegin)
        let tokens = segments.reduce(0) { $0 + $1.tokens.count }
        let columns = speechColumns(seek: seek, segmentSize: segmentSize)
        let timed = try seeker.addWordTimestamps(
            segments: segments,
            alignmentWeights: alignmentWeights.speechAlignment(rows: promptRows..<promptRows + tokens, columns: columns),
            tokenizer: tokenizer,
            seek: seek,
            segmentSize: segmentSize,
            prependPunctuations: prependPunctuations,
            appendPunctuations: appendPunctuations,
            lastSpeechTimestamp: lastSpeechTimestamp,
            options: options,
            timings: timings
        )
        // A last row that is a word ends where the alignment does, past the speech, and
        // Whisper's boundary heuristic (timing.py, add_word_timestamps) lengthens a last
        // word shorter than the median to the median, with no audio to back the time.
        // So no word ends past the speech's last column, timed as WhisperKit times it,
        // and each one held there is told.
        let lastColumn = (Float(seek) / Float(WhisperKit.sampleRate) + Float(columns - 1) * WhisperKit.secondsPerTimeToken).rounded(2)
        return timed?.map { segment in
            var segment = segment
            segment.words = segment.words?.map { word in
                guard word.end > lastColumn else { return word }
                Self.log.info("held \"\(word.word, privacy: .public)\" ending \(word.end, privacy: .public) s to the speech's last frame at \(lastColumn, privacy: .public) s")
                var word = word
                word.end = lastColumn
                return word
            }
            return segment
        }
    }
}

extension MLMultiArray {
    /// The cross-attention of `rows` over their first `columns` columns, laid out so that
    /// WhisperKit's aligner reads it as it is.
    ///
    /// WhisperKit 1.1.0 copies the rows it aligns `shape.last` elements apart into a
    /// half-precision array backed by a pixel buffer, whose rows are padded out to the
    /// buffer's alignment, and then reads that array by its padded rows. It reads the
    /// model's own alignment right only because that is padded the same way, 1504
    /// columns a row for 1500. So this alignment is as wide as a padded row, which pads
    /// to itself; a narrower one would be read shifted a little further along each row.
    ///
    /// The columns past the speech are closed to every row but the last: the warping
    /// must cross them to reach its end, and crossing them in any other row costs more
    /// than descending to the last row through the speech could, so every token but the
    /// last is placed in the speech.
    func speechAlignment(rows: Range<Int>, columns: Int) throws -> MLMultiArray {
        guard shape.count == 2, rows.upperBound <= shape[0].intValue, columns <= shape[1].intValue else {
            throw WhisperError.segmentingFailed("alignment \(shape) has no rows \(rows) of \(columns) columns")
        }
        let width = try MLMultiArray(shape: [rows.count, columns] as [NSNumber], dataType: dataType, initialValue: FloatType(0)).strides[0].intValue
        let alignment = try MLMultiArray(shape: [rows.count, width] as [NSNumber], dataType: dataType)
        let size = dataType.bytesPerElement
        let rowStride = strides[0].intValue
        withUnsafeBytes { source in
            alignment.withUnsafeMutableBytes { target, _ in
                for row in 0..<rows.count {
                    // A tensor with rows has an address; a row is contiguous, as WhisperKit reads it.
                    (target.baseAddress! + row * width * size)
                        .copyMemory(from: source.baseAddress! + (rows.lowerBound + row) * rowStride * size, byteCount: columns * size)
                }
            }
        }
        for row in 0..<rows.count {
            for column in columns..<width {
                alignment[[row, column] as [NSNumber]] = NSNumber(value: row == rows.count - 1 ? 0 : Self.closed)
            }
        }
        return alignment
    }

    /// The least attention half precision holds: a cell the warping avoids at any cost.
    static let closed: Float = -65_504
}

extension MLMultiArrayDataType {
    /// The unit the strides count in.
    var bytesPerElement: Int {
        switch self {
        case .float16: 2
        case .float32: 4
        case .double: 8
        case .int32: 4
        @unknown default: fatalError("MLMultiArrayDataType \(rawValue) has no known element size")
        }
    }
}
