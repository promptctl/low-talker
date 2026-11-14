import Foundation
import WhisperKit

/// How a vocabulary is told to Whisper: its terms as the decoder's prompt tokens, refused when
/// there are more of them than Whisper prefills.
///
/// [LAW:single-enforcer] The one rule a vocabulary is held to for Whisper, at both borders it
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

    /// The encoder for an installed Whisper model, read from the store with no Core ML load, so a
    /// vocabulary can be checked long before the model is resident: its tokenizer alone.
    /// The size and the folders searched are WhisperKit's own, mirrored in
    /// `TokenizerChoice.swift`, so this reads the `tokenizer.json` the engine will.
    static func load(_ installed: InstalledModel) async throws(PromptsUnavailable) -> PromptEncoder {
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

/// The tokenizer did not load, Whisper's or the spotter's, so no vocabulary can be checked
/// against the engine.
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
