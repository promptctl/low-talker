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

    /// A token's piece, or the refusal of an id past the vocabulary.
    func piece(_ token: TDTDecoding.EmittedToken) throws(ParakeetReadingError) -> String {
        guard pieces.indices.contains(token.id) else { throw .tokenOutsideVocabulary(token.id) }
        return pieces[token.id]
    }

    /// The tokens as transcript words from sample `cut` on, each timed from its first token's
    /// frame to the end of its last token's, at `sampleRate`, and as sure as the product of its
    /// tokens' probabilities. A word starts at each piece that starts with a space; a first piece
    /// without one starts a word too, given the leading space every transcript word carries. A
    /// word sounding mostly before the cut is no word of these, so its tokens are never read.
    ///
    /// [LAW:no-silent-failure] A control piece (`<unk>`, `<pad>`, `<|endoftext|>`, the language
    /// tags, all spelled in angle brackets) or a probability outside 0...1 in a word from the cut
    /// on fails the reading, naming it: dropped, it would leave a transcript missing what the
    /// engine heard there with nothing to say so.
    func words(_ tokens: [TDTDecoding.EmittedToken], from cut: Int) throws(ParakeetReadingError) -> [Transcript.Word] {
        var spoken: [[(token: TDTDecoding.EmittedToken, piece: String)]] = []
        for token in tokens {
            let piece = try piece(token)
            if spoken.isEmpty || piece.hasPrefix(" ") { spoken.append([]) }
            spoken[spoken.count - 1].append((token, piece))
        }
        return try spoken
            .filter { ($0.first!.token.sample + $0.last!.token.sample + ParakeetWindow.frameSamples) / 2 >= cut }
            .map { pieces throws(ParakeetReadingError) in try Self.word(pieces) }
    }

    private static func word(_ pieces: [(token: TDTDecoding.EmittedToken, piece: String)]) throws(ParakeetReadingError) -> Transcript.Word {
        var confidence: Confidence = 1.0
        for (token, piece) in pieces {
            if piece.count > 2, piece.hasPrefix("<"), piece.hasSuffix(">") { throw .controlToken(id: token.id, piece: piece) }
            guard let sure = Confidence(exactly: Double(token.probability)) else {
                throw .probabilityOutsideUnitInterval(token.probability, piece: piece)
            }
            confidence = confidence * sure
        }
        let text = pieces.map(\.piece).joined()
        return Transcript.Word(
            text: text.hasPrefix(" ") ? text : " " + text,
            time: AudioClip.duration(for: pieces.first!.token.sample)...AudioClip.duration(for: pieces.last!.token.sample + ParakeetWindow.frameSamples),
            confidence: confidence
        )
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
