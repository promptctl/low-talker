import Foundation
import Identity
import os

/// Parakeet TDT v3 on the Neural Engine, decoded by our own greedy TDT decoder over
/// FluidInference's Core ML conversion.
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

    /// Loads an installed model onto the compute units and reads its vocabulary. Returns only
    /// once the models are resident, so the first `transcribe` pays no load cost.
    public init(_ installed: InstalledModel, turns: EngineTurns) async throws {
        let network = try await CoreMLParakeet(folder: installed.folder)
        let vocabulary = try ParakeetVocabulary(json: Data(contentsOf: installed.folder.appending(path: ParakeetModel.vocabulary)))
        self.init(model: installed.model, network: network, vocabulary: vocabulary, turns: turns)
    }

    /// The engine over any network: a test hands it a scripted one.
    init(model: Model, network: any ParakeetNetwork, vocabulary: ParakeetVocabulary, turns: EngineTurns) {
        self.model = model
        reader = ParakeetReader(network: network, vocabulary: vocabulary)
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
    /// agree on are confirmed. Parakeet takes no prompt, so a vocabulary with any term is
    /// refused before audio is taken in, by the rule a config is checked with.
    public func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws(TranscriptionFailure) -> Transcription {
        let reader = reader
        let prompts = PromptEncoder.takingNone(model)
        _ = try await turns.decode(as: caller) { () throws(TranscriptionFailure) in
            do throws(VocabularyError) { return try prompts.prompt(for: vocabulary) } catch { throw .vocabulary(error) }
        }
        return try await Hearing.transcribe(audio, margin: ParakeetReader.margin, context: ParakeetReader.context, pass: { pass async throws(TranscriptionFailure) in
            try await turns.decode(as: caller) { () throws(TranscriptionFailure) in try reader.read(pass) }
        }, partial: partial)
    }
}

/// One Parakeet pass: the audio from just before the cut to the pass's end, encoded window by
/// window and decoded as one sequence of tokens, read as words.
struct ParakeetReader: Sendable {
    let network: any ParakeetNetwork
    let vocabulary: ParakeetVocabulary

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
    /// sound.
    func read(_ pass: Hearing.Pass) throws(TranscriptionFailure) -> [Transcript.Word] {
        let (tokens, facts) = try decode(pass.samples, from: max(0, pass.cut - Self.leadIn))
        Self.log.info("\(facts.description, privacy: .public)")
        let words: [Transcript.Word]
        do throws(ParakeetReadingError) { words = try vocabulary.words(tokens, from: pass.cut) } catch { throw .unreadable(.parakeet(error)) }
        guard let last = pass.prefix.last else { return words }
        let end = AudioClip.sampleCount(for: last.time.upperBound)
        // A word that starts before the prefix's last frame ends is a hearing of the prefix, its
        // punctuation running on past that end or not.
        let over = words.prefix { AudioClip.sampleCount(for: $0.time.lowerBound) < end }
        // `Hearing` keeps a confirmed word's time and takes only the text a pass reads for it.
        let reheard = over.last.flatMap { Hearing.sameWord(last, $0) ? $0 : nil } ?? last
        return pass.prefix.dropLast() + [reheard] + words.dropFirst(over.count)
    }

    /// The tokens of `samples` from `start` on, and what the decode did.
    func decode(_ samples: [Float], from start: Int) throws(TranscriptionFailure) -> ([TDTDecoding.EmittedToken], ParakeetPassFacts) {
        let spans = ParakeetWindow.spans(of: samples, from: start)
        var decoding: TDTDecoding
        do {
            decoding = try TDTDecoding(network: network)
            for span in spans {
                // A hold that wants the engine cancels the decode between windows, and the
                // turns run it again; a window already on the compute units finishes.
                if Task.isCancelled { throw TranscriptionFailure.cancelled }
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
