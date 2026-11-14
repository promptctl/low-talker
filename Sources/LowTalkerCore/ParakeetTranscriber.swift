import Foundation
import Identity
import os

/// Parakeet TDT v3 on the Neural Engine, decoded by our own greedy TDT decoder over
/// FluidInference's Core ML conversion, hearing a mode's vocabulary through our own CTC word
/// spotter beside it.
///
/// [LAW:no-shared-mutable-globals] Core ML models are not re-entered mid-decode: every pass
/// goes through the `EngineTurns` the engine was loaded with, as WhisperKit's does.
///
/// [LAW:one-type-per-behavior] Dictation and the server hear through the same engine; `served`
/// is this value with its caller changed.
public struct ParakeetTranscriber: Transcriber {
    public let model: Model
    private let reader: ParakeetReader
    private let turns: EngineTurns
    private var caller: EngineTurns.Caller

    /// Loads an installed model and its spotter onto the compute units and reads their
    /// vocabularies. Returns only once the models are resident, so the first `transcribe` pays no
    /// load cost.
    public init(_ installed: InstalledModel, turns: EngineTurns) async throws {
        let network = try await CoreMLParakeet(folder: installed.folder)
        let vocabulary = try ParakeetVocabulary(json: Data(contentsOf: installed.folder.appending(path: ParakeetModel.vocabulary)))
        let spotter = try await CoreMLSpotter(encoder: installed.folder(of: .spotterEncoder), head: installed.folder(of: .spotterHead))
        let tokenizer = try SpotterTokenizer(json: Data(contentsOf: installed.folder(of: .spotterHead).appending(path: ParakeetModel.spotterTokenizer)))
        self.init(model: installed.model, network: network, vocabulary: vocabulary, spotter: spotter, tokenizer: tokenizer, turns: turns)
    }

    /// The engine over any networks: a test hands it scripted ones.
    init(model: Model, network: any ParakeetNetwork, vocabulary: ParakeetVocabulary, spotter: any SpotterNetwork, tokenizer: SpotterTokenizer, turns: EngineTurns) {
        self.model = model
        reader = ParakeetReader(network: network, vocabulary: vocabulary, spotter: spotter, tokenizer: tokenizer)
        self.turns = turns
        caller = .dictation
    }

    /// The same engine, hearing for callers the server answers.
    public var served: ParakeetTranscriber {
        var served = self
        served.caller = .served
        return served
    }

    /// Hears the utterance in passes as its audio arrives, as WhisperKit's engine does: each
    /// pass decodes from a few confirmed words back to the audio so far, and words two passes
    /// agree on are confirmed. Parakeet takes no prompt: the vocabulary's terms are spelled in
    /// the spotter's pieces once, before audio is taken in, by the rule a config is checked
    /// with, and every pass searches its audio for them.
    public func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws(TranscriptionFailure) -> Transcription {
        // Spelling reads nothing on the compute units, so it takes no turn.
        let terms: [SpelledTerm]
        do throws(VocabularyError) { terms = try reader.tokenizer.terms(vocabulary) } catch { throw .vocabulary(error) }
        let reader = reader
        return try await Hearing.transcribe(audio, margin: ParakeetReader.margin, context: ParakeetReader.context, pass: { pass async throws(TranscriptionFailure) in
            try await turns.decode(as: caller) { () throws(TranscriptionFailure) in try reader.read(pass, hearing: terms) }
        }, partial: partial)
    }
}

/// One Parakeet pass: the audio from just before the cut to the pass's end, encoded window by
/// window and decoded as one sequence of tokens, read as words, with the terms the spotter finds
/// in the same audio in place of the words they were heard as.
struct ParakeetReader: Sendable {
    let network: any ParakeetNetwork
    let vocabulary: ParakeetVocabulary
    let spotter: any SpotterNetwork
    let tokenizer: SpotterTokenizer

    /// A settled word ends a second before the pass's end, and a first pass waits for a second
    /// of speech: the encoder attends across its whole window, so the last words it reads are
    /// the ones the next pass's added audio is likeliest to change.
    static let margin = AudioClip.sampleCount(for: 1)
    /// Confirmed words a pass reads again, as WhisperKit's do, so the last of them may be
    /// re-punctuated by the words after it.
    static let context = 3
    /// Audio read before the cut, so the first confirmed word is heard with the sound before it
    /// rather than from its first sample. Parakeet cannot be told the words to say first; it
    /// re-hears them, and the lead-in is what lets it hear them as it did.
    ///
    /// Whole frames, about half a second: a word's time is its frame's, and the cut is a
    /// confirmed word's start, so a pass whose frames start a whole number of frames before
    /// the cut puts that word back on the frame it was confirmed on. [LAW:one-source-of-truth]
    static let leadIn = 6 * ParakeetWindow.frameSamples

    static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "parakeet")

    /// The pass's words from the cut on, timed from the pass's first sample, its prefix first as
    /// `Hearing` reads it. Parakeet is not told the prefix, it hears it again, so the words heard
    /// over the prefix's audio are the prefix as told, the last with the punctuation this pass
    /// hears on it: a prefix word heard another way is then not heard twice, once confirmed and
    /// once as a new word. The words the lead-in heard before the cut are dropped by where they
    /// sound, and so are the terms the spotter found there.
    func read(_ pass: Hearing.Pass, hearing terms: [SpelledTerm]) throws(TranscriptionFailure) -> [Transcript.Word] {
        let start = max(0, pass.cut - Self.leadIn)
        var (tokens, facts) = try decode(pass.samples, from: start)
        // Logged however the pass ends, so a pass the spotter or the reading fails still says
        // what the decode did.
        defer { Self.log.info("\(facts.description, privacy: .public)") }
        let spotted = try spot(pass.samples, from: start, hearing: terms, facts: &facts)
            .filter { HeardWord.sounds(from: $0.first!.first, to: $0.last!.last, after: pass.cut) }
        facts.spotted = spotted.count
        let words: [Transcript.Word]
        do throws(ParakeetReadingError) {
            words = HeardWord.merging(spotted, into: try vocabulary.words(tokens, from: pass.cut)).map(\.transcript)
        } catch { throw .unreadable(.parakeet(error)) }
        guard let last = pass.prefix.last else { return words }
        // The words that start before the last prefix word are hearings of the words before it,
        // and the next is the last's if it starts before that word's last frame ends, its
        // punctuation running on past that end or not. Only that one: a word emitted after it
        // on the same frame is a new word.
        let before = words.prefix { $0.time.lowerBound < last.time.lowerBound }
        let lastHeard = words.dropFirst(before.count).first.map { $0.time.lowerBound < last.time.upperBound } ?? false
        let over = words.prefix(before.count + (lastHeard ? 1 : 0))
        // `Hearing` keeps a confirmed word's time and takes only the text a pass reads for it.
        let reheard = over.last.flatMap { Hearing.sameWord(last, $0) ? $0 : nil } ?? last
        return pass.prefix.dropLast() + [reheard] + words.dropFirst(over.count)
    }

    /// The `terms` the spotter finds in `samples` from `start` on, each as its words, timed from
    /// the pass's first sample. No term is nothing to find, so its pass reads no audio for it.
    func spot(_ samples: [Float], from start: Int, hearing terms: [SpelledTerm], facts: inout ParakeetPassFacts) throws(TranscriptionFailure) -> [[HeardWord]] {
        guard !terms.isEmpty else { return [] }
        var frames: [[Float]] = []
        do {
            for span in ParakeetWindow.spans(of: samples, from: start) {
                if Task.isCancelled { throw TranscriptionFailure.cancelled }
                frames += try spotter.logProbabilities(samples[span]).prefix(ParakeetWindow.frames(startedBy: span))
            }
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw .engine(error)
        }
        let spotting = CTCWordSpotter(terms: terms, blank: SpotterClasses.blank, wordStarts: tokenizer.wordStarts).spot(frames)
        facts.spotterFrames = frames.count
        facts.candidates = spotting.candidates
        facts.outscored = spotting.outscored
        do throws(ParakeetReadingError) {
            return try spotting.hits.map { hit throws(ParakeetReadingError) in try hit.words(from: start) }
        } catch { throw .unreadable(.parakeet(error)) }
    }

    /// The tokens of `samples` from `start` on, and what the decode did.
    func decode(_ samples: [Float], from start: Int) throws(TranscriptionFailure) -> ([TDTDecoding.EmittedToken], ParakeetPassFacts) {
        let spans = ParakeetWindow.spans(of: samples, from: start)
        var decoding: TDTDecoding
        do {
            decoding = try TDTDecoding(network: network)
            for span in spans {
                try decoding.decode(network.encode(samples[span]), over: span)
            }
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch let reading as ParakeetReadingError {
            throw .unreadable(.parakeet(reading))
        } catch {
            throw .engine(error)
        }
        var facts = decoding.facts
        facts.samples = samples.count - start
        return (decoding.tokens, facts)
    }
}

extension ParakeetWindow {
    /// Where to cut `samples` from `start` into windows the encoder takes whole. A window
    /// longer than the encoder's is cut before the quietest frame of its last two seconds, so
    /// the cut falls in a pause rather than through a word, and on a frame boundary, so every
    /// window's frames continue the pass's. Where there is no pause, the quietest
    /// frame is still where it falls: a word there is heard in two halves, which is the cost of
    /// a model whose input is a fixed 15 s.
    ///
    /// [LAW:dataflow-not-control-flow] One loop for every length: audio within one window is
    /// one span, and the same loop cuts any more.
    static func spans(of samples: [Float], from start: Int) -> [Range<Int>] {
        let search = AudioClip.sampleCount(for: 2) / frameSamples
        var spans: [Range<Int>] = []
        var lower = start
        while samples.count - lower > Self.samples {
            let lastWhole = Self.samples / frameSamples - 1
            // Latest first, so of frames equally quiet the window keeps the most audio.
            let quietest = (lastWhole - search...lastWhole).reversed().min { energy(samples, frame: $0, from: lower) < energy(samples, frame: $1, from: lower) }!
            let upper = lower + quietest * frameSamples
            spans.append(lower..<upper)
            lower = upper
        }
        spans.append(lower..<samples.count)
        return spans
    }

    private static func energy(_ samples: [Float], frame: Int, from lower: Int) -> Float {
        let first = lower + frame * frameSamples
        return samples[first..<first + frameSamples].reduce(0) { $0 + $1 * $1 }
    }
}
