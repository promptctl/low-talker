import Foundation
import WhisperKit

/// How a vocabulary is told to the engine: its terms as the decoder's prompt tokens,
/// refused when there are more of them than Whisper prefills, or refused outright by an
/// engine that hears none.
///
/// [LAW:single-enforcer] The one rule a vocabulary is held to, at both borders it
/// crosses: the config file, where a mode's terms are read before any press can use
/// them, and the engine, where the server's prompt and the bench's terms arrive with
/// the audio. [LAW:no-silent-failure] Past the limit WhisperKit would keep the last of
/// the prompt and say nothing, losing the first terms without a word said; this refuses
/// the vocabulary with its size instead.
public struct PromptEncoder: Sendable {
    /// The vocabulary as the decoder's prompt tokens, or why the engine cannot be told it.
    private let encode: @Sendable (Vocabulary) throws(VocabularyError) -> [Int]

    /// An encoder over any tokenization, keeping at most `limit` tokens; a test hands it one
    /// it can count by eye.
    public init(limit: Int, tokens: @escaping @Sendable (String) -> [Int]) {
        encode = { vocabulary throws(VocabularyError) in
            let tokens = tokens(vocabulary.whisperPrompt)
            guard tokens.count <= limit else { throw .tooLong(tokens: tokens.count, limit: limit) }
            return tokens
        }
    }

    /// The encoder of an engine that takes no vocabulary: no terms is no prompt, and any
    /// term is refused naming `model`. Parakeet's, until its word spotter (low-engines-7ht.eed)
    /// gives it a vocabulary to hear.
    public static func takingNone(_ model: Model) -> PromptEncoder {
        PromptEncoder { vocabulary throws(VocabularyError) in
            guard vocabulary.terms.isEmpty else { throw .engineTakesNone(model) }
            return []
        }
    }

    private init(encode: @escaping @Sendable (Vocabulary) throws(VocabularyError) -> [Int]) {
        self.encode = encode
    }

    /// Whisper's: the tokens WhisperKit would keep, its special tokens filtered out as
    /// its decoder does, up to the most it prefills. Every prompt token also takes one of
    /// the decoder steps a window has (`Constants.maxTokenContext` less one, prefill
    /// included), so a long vocabulary leaves a 30 s window fewer words to read.
    init(whisper tokenizer: any WhisperTokenizer) {
        let tokenizer = Tokenizer(whisper: tokenizer)
        self.init(limit: SpeechAlignedSegmentSeeker.promptTokenLimit) { text in
            tokenizer.whisper.encode(text: text).filter { $0 < tokenizer.whisper.specialTokens.specialTokenBegin }
        }
    }

    /// `vocabulary` as the decoder's prompt, or why the engine cannot be told it.
    public func prompt(for vocabulary: Vocabulary) throws(VocabularyError) -> [Int] {
        try encode(vocabulary)
    }

    /// The encoder for `installed`, read from the store with no Core ML load, so a vocabulary
    /// can be checked long before the model is resident: Whisper's tokenizer alone, or
    /// Parakeet's refusal of every term.
    /// The size and the folders searched are WhisperKit's own, mirrored in
    /// `TokenizerChoice.swift`, so this reads the `tokenizer.json` the engine will.
    public static func load(_ installed: InstalledModel) async throws(PromptsUnavailable) -> PromptEncoder {
        // [LAW:types-are-the-program] Exhaustive, so an engine added to `Model` says here how it
        // is told a vocabulary before it compiles.
        switch installed.model {
        case .whisperKit: break
        case .parakeet: return .takingNone(installed.model)
        }
        do {
            let variant = try ModelVariant(modelConfig: Data(contentsOf: installed.folder.appending(path: "config.json")))
            let tokenizer = try await ModelUtilities.loadTokenizer(
                for: variant,
                tokenizerFolder: installed.hub,
                additionalSearchPaths: variant.tokenizerSearchPaths(in: installed.folder)
            )
            return PromptEncoder(whisper: tokenizer)
        } catch {
            throw PromptsUnavailable(why: "\(error)")
        }
    }

    /// `@unchecked Sendable` because WhisperKit's tokenizer is a class the compiler cannot
    /// vouch for. Encoding reads it and writes nothing.
    private struct Tokenizer: @unchecked Sendable {
        let whisper: any WhisperTokenizer
    }
}

/// The tokenizer did not load, so no vocabulary can be checked against the engine.
///
/// Not a `ConfigError`: the file may be fine. What failed is the model the app carries,
/// and the config is not read at all rather than read unchecked. [LAW:no-silent-failure]
public struct PromptsUnavailable: Error, Equatable, Sendable, CustomStringConvertible {
    public let why: String

    public init(why: String) {
        self.why = why
    }

    public var description: String {
        "the model's tokenizer did not load, so no mode's vocabulary can be checked: \(why)"
    }
}
