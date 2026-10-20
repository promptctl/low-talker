import Foundation
import Identity
import os
import WhisperKit

/// Whisper on the Neural Engine through WhisperKit.
///
/// [LAW:no-shared-mutable-globals] WhisperKit's pipeline is a mutable class that must
/// not be re-entered mid-decode. Every decode goes through the `EngineTurns` it was loaded
/// with, which runs them one at a time and decides whose goes next, and nothing else can
/// reach the pipeline.
///
/// [LAW:one-type-per-behavior] Dictation and the server hear through the same engine; what
/// differs is only who is asking, so `served` is this value with its caller changed.
public struct WhisperKitTranscriber: Transcriber {
    public let model: ModelName
    private let pipeline: Pipeline
    private let gate: GateClassifier
    private let turns: EngineTurns
    private var caller: EngineTurns.Caller

    /// Loads an installed model onto the compute units, its weights from disk alone, and
    /// the gate classifier beside it. Returns only once both are resident, so the first
    /// `transcribe` pays no load cost. It hears for dictation; `served` is the same engine
    /// for the server.
    public init(_ installed: InstalledModel, turns: EngineTurns) async throws {
        model = installed.model
        pipeline = try await Pipeline(installed: installed)
        gate = try await GateClassifier()
        self.turns = turns
        caller = .dictation
    }

    /// The same engine, hearing for callers the server answers: its decodes give way to
    /// every hold `turns` is given.
    public var served: WhisperKitTranscriber {
        var served = self
        served.caller = .served
        return served
    }

    /// Loads a model a store already holds, verified in place and never written to: the
    /// app's carried store is read-only and code-signed, so the model is confirmed
    /// whole where it sits, with no install and no lock. There is no installing phase — a
    /// store that does not hold the model whole fails with the reason before any load
    /// begins. [LAW:parse-dont-validate]
    public static func loadInPlace(
        _ model: ModelName = .default,
        in store: ModelStore,
        turns: EngineTurns,
        phase: @escaping @Sendable (LoadPhase) -> Void
    ) async throws -> WhisperKitTranscriber {
        let installed = try store.installedModel(model)
        phase(.loading)
        return try await WhisperKitTranscriber(installed, turns: turns)
    }

    /// What a load is doing right now. One step, because a store this module loads is
    /// already whole: the road that first installs into a store, with its own phases, is
    /// `ModelInstall`'s. There is no "ready" case: the returned transcriber is that state.
    public enum LoadPhase: Equatable, Sendable, CustomStringConvertible {
        /// Core ML is loading the model. The first load on a Mac, after an OS update,
        /// or after a change to the app's signing identity also specializes the model
        /// for the Neural Engine, which takes minutes.
        case loading

        public var description: String {
            switch self {
            case .loading: "loading model, minutes the first time on this Mac"
            }
        }
    }

    /// Hears the utterance in passes as its audio arrives. Whisper decodes a whole
    /// window at a time, so streaming is re-reading: each pass decodes from a few
    /// confirmed words back to the audio so far, and words two passes agree on are
    /// confirmed, read again only as a later pass's prefix, which may re-punctuate
    /// the last of them. A pass runs whenever the engine is free and speech has
    /// arrived since the last one, so the partials are as fresh as the engine
    /// allows; the pass that covers the last of the speech is the last pass,
    /// whether the key is still down when it starts or has already come up.
    public func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws(TranscriptionFailure) -> Transcription {
        let pipeline = pipeline
        // The vocabulary is encoded once and refused, if it must be, before any
        // audio is taken in, so a hold never gets as far as the gate with a prompt
        // the engine cannot carry.
        let prompt = try await turns.decode(as: caller) { () throws(TranscriptionFailure) in
            do throws(VocabularyError) { return try pipeline.prompt(for: vocabulary) } catch { throw .vocabulary(error) }
        }
        // [LAW:composability] The passes are Hearing's to run; this engine is one
        // decode of what a pass asks for, and its floor and prefix length are the
        // facts it hands over.
        return try await Hearing.transcribe(audio, margin: Pipeline.margin, context: Pipeline.contextWords, judging: gate, pass: { pass async throws(TranscriptionFailure) in
            try await turns.decode(as: caller) { () async throws(TranscriptionFailure) in try await pipeline.hear(pass.samples, arrived: pass.arrived, from: pass.cut, saying: pass.saying, told: prompt) }
        }, partial: partial)
    }

    /// The loaded WhisperKit pipeline. `@unchecked Sendable` because WhisperKit is a
    /// mutable class the compiler cannot vouch for; `EngineTurns` is what keeps
    /// every decode alone with it. Internal, not private, so the tests can reach the
    /// windowing arithmetic without a model.
    struct Pipeline: @unchecked Sendable {
        private let whisperKit: WhisperKit
        private let tokenizer: any WhisperTokenizer

        /// Word timings are the whole point: without them a result carries no per-word
        /// confidence and the mapping refuses it. A segment's text is its words alone:
        /// with the special tokens left in, a pass that heard nothing comes back as
        /// "<|startoftranscript|><|en|>...<|endoftext|>" with no words, which the
        /// mapping would rightly refuse as speech that lost its words.
        ///
        /// One decode a pass, at temperature zero: WhisperKit's temperature ladder is
        /// off. By default it re-decodes a window up to five times at rising
        /// temperatures when the reading looks repetitive or under-confident, each
        /// rung a full decoder loop over the same encoder output, so one pass could
        /// cost several. On the bench it fired on nothing but mid-hold passes cut
        /// into a word, up to 4.4 s against 0.6 s, with the key-up waiting behind
        /// them, and its upper rungs read back stutter or nothing where the next pass
        /// read the words plainly; no final pass over a whole utterance ever climbed
        /// it. The first-token threshold goes with the ladder: it ends a decode at
        /// one doubtful token so the next rung can start sooner, and with no rung to
        /// fall to it would hand back that one token as the reading.
        static let decodeOptions = DecodingOptions(
            temperatureFallbackCount: 0,
            skipSpecialTokens: true,
            wordTimestamps: true,
            firstTokenLogProbThreshold: nil
        )

        /// [LAW:one-source-of-truth] WhisperKit decodes no window that starts within
        /// `windowClipTime` of the clip's end, its guard against hallucinating over a
        /// trailing sliver. A word is confirmed only when it ended this far before the
        /// pass's end, so the next pass, starting at that word, always spans more; and
        /// a pass over less than this from its cut, the whole of an utterance shorter
        /// than a second, is padded out past it by `window(_:from:)`.
        static let margin = AudioClip.sampleCount(for: Double(decodeOptions.windowClipTime))

        /// The audio a pass reads: `samples`, run out with silence to one sample more
        /// than `margin` past `cut` when they fall short of it, so the engine's guard
        /// sees a window it will decode. Silence after the speech is what the encoder
        /// pads every window with anyway, so the reading is the same as the guard
        /// would have given a longer clip; and audio already past the floor is
        /// untouched, so a real trailing sliver is still refused as it was.
        ///
        /// [LAW:effects-at-boundaries] Pure, so the arithmetic is tested without a
        /// model; `hear` is the effect that reads what this returns.
        static func window(_ samples: [Float], from cut: Int) -> [Float] {
            samples + Array(repeating: 0, count: max(0, cut + margin + 1 - samples.count))
        }

        /// Confirmed words a pass starts from, forced as its first tokens rather than
        /// prompted as earlier text: a prompt is decoded against audio that no longer
        /// holds it, and Whisper then reads the prompted words a second time out of
        /// the audio that follows, so the prefix is forced over the audio that does
        /// hold it and its reading is dropped. Each forced token costs a decoder step,
        /// the same as decoding it, so the prefix is a few words, not every confirmed one.
        static let contextWords = 3

        static let alignmentLog = Logger(subsystem: AppIdentity.bundleIdentifier, category: "alignment")

        /// Nonisolated on purpose: the non-Sendable WhisperKit is created and wrapped
        /// here without crossing an isolation boundary.
        nonisolated init(installed: InstalledModel) async throws {
            // WhisperKit logs to stdout when verbose; stdout belongs to whoever called us.
            // `download` gates only the weights, which `modelFolder` supplies; the
            // tokenizer is read from `tokenizerFolder`, where the install put it.
            whisperKit = try await WhisperKit(WhisperKitConfig(
                modelFolder: installed.folder.path,
                tokenizerFolder: installed.hub,
                verbose: false,
                load: true,
                download: false
            ))
            // [LAW:parse-dont-validate] WhisperKit loads its tokenizer with the model
            // and holds it as an optional; it is unwrapped here, once, so every pass
            // has one to encode its prefix with.
            guard let tokenizer = whisperKit.tokenizer else {
                throw WhisperKitTranscriberError.tokenizerNotLoaded(installed.model)
            }
            self.tokenizer = tokenizer
        }

        /// The vocabulary as the decoder's prompt: the text of a segment before the
        /// utterance, which is how Whisper is told spellings it could not guess.
        /// Told " Brynleigh Fryslie" and then hearing the names, it writes them so
        /// rather than "Brynley Frisley". The prompt stands before the start of the
        /// transcript and the forced prefix after it, so one pass carries both. A
        /// prompt is decoded against audio that does not hold it, and Whisper will
        /// read prompted words a second time out of the audio that follows when
        /// they were the words just heard; a list of terms is not, which is why the
        /// vocabulary goes here and the confirmed words go in the prefix.
        ///
        /// [LAW:no-silent-failure] A vocabulary past WhisperKit's prompt limit is
        /// refused with its size, where WhisperKit would keep the last of it and say
        /// nothing, losing the first terms without a word said. The count is of the
        /// tokens WhisperKit would keep, its special tokens filtered out as its
        /// decoder does. Every prompt token also takes one of the decoder steps a
        /// window has (`Constants.maxTokenContext` less one, prefill included), so a
        /// long vocabulary leaves a 30 s window fewer words to read.
        func prompt(for vocabulary: Vocabulary) throws(VocabularyError) -> [Int] {
            let tokens = tokenizer.encode(text: vocabulary.whisperPrompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            let limit = SpeechAlignedSegmentSeeker.promptTokenLimit
            guard tokens.count <= limit else {
                throw .tooLong(tokens: tokens.count, limit: limit)
            }
            return tokens
        }

        /// One pass: the words in `samples` from `cut` on, the first of them forced to
        /// read `prefix`, the text spoken from the cut, with `prompt` as the text
        /// before the utterance. Times are from the utterance's start, and the
        /// prefix's words come back first, timed over their own audio, which is the
        /// first `arrived` of the samples. Samples short of the engine's floor are
        /// padded out to it; see `window(_:from:)`.
        ///
        /// [LAW:parse-dont-validate] The border with WhisperKit: what its library throws is
        /// its own, and what its reading cannot become is ours, each named once here.
        func hear(_ samples: [Float], arrived: Int, from cut: Int, saying prefix: String, told prompt: [Int]) async throws(TranscriptionFailure) -> [Transcript.Word] {
            var options = Self.decodeOptions
            options.clipTimestamps = [Float(AudioClip.duration(for: cut))]
            options.promptTokens = prompt
            options.prefixTokens = tokenizer.encode(text: prefix)
            // The seeker is ours so that a prompted pass keeps its word timings and no
            // word is timed past its audio, and it is this pass's: the task WhisperKit's
            // `transcribe` runs over a window it does not chunk is built here with it,
            // rather than reading one the shared pipeline holds.
            let seeker = SpeechAlignedSegmentSeeker(arrived: arrived, told: { Self.alignmentLog.info("\($0.description, privacy: .public)") })
            let task = TranscribeTask(
                currentTimings: whisperKit.currentTimings, progress: nil, audioProcessor: whisperKit.audioProcessor,
                audioEncoder: whisperKit.audioEncoder, featureExtractor: whisperKit.featureExtractor, segmentSeeker: seeker,
                textDecoder: whisperKit.textDecoder, tokenizer: tokenizer
            )
            let result: TranscriptionResult
            do {
                result = try await task.run(audioArray: Self.window(samples, from: cut), decodeOptions: options)
            } catch {
                throw .engine(error)
            }
            do throws(WhisperKitTranscriberError) {
                return try Transcript(whisperKit: result.segments).words
            } catch {
                throw .unreadable(error)
            }
        }
    }
}

public enum WhisperKitTranscriberError: Error, CustomStringConvertible {
    /// WhisperKit returned a segment with speech in its text but no word timings to
    /// carry it, so the text would be lost.
    case speechWithoutWords(text: String)
    case probabilityOutsideUnitInterval(WordTiming)
    case wordEndsBeforeStart(WordTiming)
    /// WhisperKit loaded the model but holds no tokenizer for it.
    case tokenizerNotLoaded(ModelName)

    public var description: String {
        switch self {
        case .tokenizerNotLoaded(let model):
            "WhisperKit loaded \(model) without its tokenizer"
        case .speechWithoutWords(let text):
            "WhisperKit returned segment \"\(text)\" without word timings"
        case .probabilityOutsideUnitInterval(let word):
            "WhisperKit gave word \"\(word.word)\" probability \(word.probability), outside \(Confidence.range)"
        case .wordEndsBeforeStart(let word):
            "WhisperKit gave word \"\(word.word)\" end \(word.end) before start \(word.start)"
        }
    }
}

extension Vocabulary {
    /// The terms as the text of a segment said before the utterance: each with the
    /// leading space a spoken word carries and nothing between them, so
    /// " Brynleigh Fryslie Jaxxon". Commas between the terms read back into the
    /// transcript: told " Brynleigh, Fryslie", Whisper wrote "Brynleigh," for the
    /// name spoken mid-sentence, while the bare list biased the same names as well
    /// or better and punctuated nothing. No terms is no text and so no prompt at
    /// all, which is what WhisperKit makes of no tokens; a prompt of nothing but
    /// its start token leans the decoder toward ending the segment early.
    var whisperPrompt: String {
        terms.map { " " + $0.text }.joined()
    }
}

extension Transcript {
    /// The words of every segment, in order, as WhisperKit emitted them: each word
    /// carries its own leading space and trailing punctuation, which is exactly the
    /// convention `Transcript.text` relies on.
    ///
    /// [LAW:parse-dont-validate] WhisperKit's optional word list and unbounded floats
    /// become non-optional words, a ClosedRange, and a Confidence here, once. Anything
    /// that does not fit is refused loudly rather than clamped, including a segment
    /// whose speech has no words to carry it: the words are the transcript, so speech
    /// with no words would simply vanish.
    public init(whisperKit segments: [TranscriptionSegment]) throws(WhisperKitTranscriberError) {
        var words: [Word] = []
        for segment in segments {
            let timings = segment.words ?? []
            guard !timings.isEmpty || !segment.text.contains(where: { !$0.isWhitespace }) else {
                throw .speechWithoutWords(text: segment.text)
            }
            for timing in timings { words.append(try Word(whisperKit: timing)) }
        }
        self.init(words: words)
    }
}

extension Transcript.Word {
    public init(whisperKit timing: WordTiming) throws(WhisperKitTranscriberError) {
        guard let confidence = Confidence(exactly: Double(timing.probability)) else {
            throw WhisperKitTranscriberError.probabilityOutsideUnitInterval(timing)
        }
        guard timing.start <= timing.end else {
            throw WhisperKitTranscriberError.wordEndsBeforeStart(timing)
        }
        self.init(text: timing.word, time: Double(timing.start)...Double(timing.end), confidence: confidence)
    }
}
