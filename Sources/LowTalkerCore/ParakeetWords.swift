import Foundation

/// Parakeet's SentencePiece vocabulary: the text of each token the joint can emit, read from
/// the `parakeet_v3_vocab.json` beside the models, which maps each id, as a string, to its
/// piece. A piece that starts a word starts with a space.
///
/// [LAW:parse-dont-validate] Read once at load: ids run 0 up to one short of the blank with
/// none missing, so a token id the decoder emits either names a piece or is refused by name.
public struct ParakeetVocabulary: Sendable {
    private let pieces: [String]

    public init(pieces: [String]) throws(ParakeetLoadError) {
        guard pieces.count == ParakeetWindow.blank else {
            throw .vocabulary("it holds \(pieces.count) pieces where the joint emits \(ParakeetWindow.blank) and the blank")
        }
        self.pieces = pieces
    }

    public init(json: Data) throws(ParakeetLoadError) {
        let byID: [String: String]
        do { byID = try JSONDecoder().decode([String: String].self, from: json) } catch {
            throw .vocabulary("it is not an object of ids to pieces: \(error)")
        }
        let pieces = try (0..<byID.count).map { id throws(ParakeetLoadError) in
            guard let piece = byID[String(id)] else { throw .vocabulary("it has no piece for id \(id) of \(byID.count)") }
            return piece
        }
        try self.init(pieces: pieces)
    }

    /// A token's piece, or why it is no part of a transcript: past the vocabulary, or one of
    /// the control pieces (`<unk>`, `<pad>`, `<|endoftext|>`, the language tags) the vocabulary
    /// spells in angle brackets.
    func piece(_ token: TDTDecoding.EmittedToken) throws(ParakeetReadingError) -> String {
        guard pieces.indices.contains(token.id) else { throw .tokenOutsideVocabulary(token.id) }
        let piece = pieces[token.id]
        if piece.count > 2, piece.hasPrefix("<"), piece.hasSuffix(">") { throw .controlToken(id: token.id, piece: piece) }
        return piece
    }

    /// The tokens as transcript words, each timed from its first token's frame to the end of
    /// its last token's, at `sampleRate`, and as sure as the product of its tokens'
    /// probabilities. A word starts at each piece that starts with a space; a first piece
    /// without one starts a word too, given the leading space every transcript word carries.
    ///
    /// [LAW:no-silent-failure] A control token or a probability outside 0...1 fails the
    /// reading, naming it: dropped, it would leave a transcript missing what the engine heard
    /// there with nothing to say so.
    func words(_ tokens: [TDTDecoding.EmittedToken]) throws(ParakeetReadingError) -> [Transcript.Word] {
        var words: [Transcript.Word] = []
        for token in tokens {
            let piece = try piece(token)
            guard let confidence = Confidence(exactly: Double(token.probability)) else {
                throw .probabilityOutsideUnitInterval(token.probability, piece: piece)
            }
            let start = AudioClip.duration(for: token.sample)
            let end = AudioClip.duration(for: token.sample + ParakeetWindow.frameSamples)
            if let last = words.last, !piece.hasPrefix(" ") {
                words[words.count - 1] = Transcript.Word(text: last.text + piece, time: last.time.lowerBound...end, confidence: last.confidence * confidence)
            } else {
                words.append(Transcript.Word(text: piece.hasPrefix(" ") ? piece : " " + piece, time: start...end, confidence: confidence))
            }
        }
        return words
    }
}

/// A Parakeet model that could not be loaded: its files, its vocabulary, or a model whose inputs
/// and outputs are not the ones the decoder is written against.
public enum ParakeetLoadError: Error, Equatable, Sendable, CustomStringConvertible {
    case vocabulary(String)
    /// A model's interface, named with what differs from the published one.
    case interface(model: String, String)

    public var description: String {
        switch self {
        case .vocabulary(let why): "the Parakeet vocabulary cannot be read: \(why)"
        case .interface(let model, let why): "\(model) is not the model the Parakeet decoder reads: \(why)"
        }
    }
}

/// A reading Parakeet made of the audio that could not become a transcript.
public enum ParakeetReadingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The joint chose a duration index the model's durations do not have.
    case durationOutOfRange(Int)
    /// The joint chose a token past the vocabulary.
    case tokenOutsideVocabulary(Int)
    /// The joint chose a control piece, such as `<unk>`, where speech was.
    case controlToken(id: Int, piece: String)
    /// The joint gave a token a probability outside 0...1.
    case probabilityOutsideUnitInterval(Float, piece: String)

    public var description: String {
        switch self {
        case .durationOutOfRange(let index): "Parakeet's joint chose duration index \(index) of \(ParakeetWindow.durations.count)"
        case .tokenOutsideVocabulary(let id): "Parakeet's joint chose token \(id), past its vocabulary of \(ParakeetWindow.blank)"
        case .controlToken(let id, let piece): "Parakeet's joint chose control token \(id) \(piece)"
        case .probabilityOutsideUnitInterval(let probability, let piece): "Parakeet gave \"\(piece)\" a probability \(probability), outside \(Confidence.range)"
        }
    }
}
