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

    /// The tokens as words from sample `cut` on, each timed from its first token's frame to the
    /// end of its last token's and as sure as the product of its tokens' probabilities. A word
    /// starts at each piece that starts with a space; a first piece without one starts a word
    /// too, given the leading space every transcript word carries. A word sounding mostly before
    /// the cut is no word of these, so its tokens are never read.
    ///
    /// [LAW:no-silent-failure] A control piece (`<unk>`, `<pad>`, `<|endoftext|>`, the language
    /// tags, all spelled in angle brackets) or a probability outside 0...1 in a word from the cut
    /// on fails the reading, naming it: dropped, it would leave a transcript missing what the
    /// engine heard there with nothing to say so.
    func words(_ tokens: [TDTDecoding.EmittedToken], from cut: Int) throws(ParakeetReadingError) -> [HeardWord] {
        var spoken: [[(token: TDTDecoding.EmittedToken, piece: String)]] = []
        for token in tokens {
            let piece = try piece(token)
            if spoken.isEmpty || piece.hasPrefix(" ") { spoken.append([]) }
            spoken[spoken.count - 1].append((token, piece))
        }
        return try spoken
            .filter { HeardWord.sounds(from: $0.first!.token.sample, to: $0.last!.token.sample, after: cut) }
            .map { pieces throws(ParakeetReadingError) in try Self.word(pieces) }
    }

    private static func word(_ pieces: [(token: TDTDecoding.EmittedToken, piece: String)]) throws(ParakeetReadingError) -> HeardWord {
        var confidence: Confidence = 1.0
        for (token, piece) in pieces {
            if piece.count > 2, piece.hasPrefix("<"), piece.hasSuffix(">") { throw .controlToken(id: token.id, piece: piece) }
            confidence = confidence * (try Self.sure(token.probability, piece))
        }
        let text = pieces.map(\.piece).joined()
        return HeardWord(text: text.hasPrefix(" ") ? text : " " + text, first: pieces.first!.token.sample, last: pieces.last!.token.sample, confidence: confidence)
    }

    static func sure(_ probability: Float, _ piece: String) throws(ParakeetReadingError) -> Confidence {
        guard let sure = Confidence(exactly: Double(probability)) else { throw .probabilityOutsideUnitInterval(probability, piece: piece) }
        return sure
    }
}

/// A word a Parakeet pass heard, timed in samples from the pass's first: from the frame its
/// first piece sounded on to the frame its last piece sounded on, which it holds whole.
struct HeardWord: Equatable, Sendable {
    let text: String
    let first: Int
    let last: Int
    let confidence: Confidence

    /// [LAW:one-source-of-truth] Where a word sounding from the frame at `first` to the frame at
    /// `last` is heard: on the side of `cut` its midpoint is. The cut and the merge of spotted
    /// words both place a word by this.
    static func sounds(from first: Int, to last: Int, after cut: Int) -> Bool {
        (first + last + ParakeetWindow.frameSamples) / 2 >= cut
    }

    /// Whether this word's midpoint is among the frames from `first` to `last`.
    func sounds(within first: Int, _ last: Int) -> Bool {
        Self.sounds(from: self.first, to: self.last, after: first) && !Self.sounds(from: self.first, to: self.last, after: last + ParakeetWindow.frameSamples)
    }

    var transcript: Transcript.Word {
        Transcript.Word(text: text, time: AudioClip.duration(for: first)...AudioClip.duration(for: last + ParakeetWindow.frameSamples), confidence: confidence)
    }

    /// `heard` with each of `spotted`'s terms in place of the words whose midpoints fall within
    /// the frames it was heard over. A term with none takes its place among them by time. The last word of a term keeps
    /// the punctuation of the last word it replaced, which the spotter cannot hear, past what the
    /// term already spells: "Frisley," is "Fryslie,", and "Yahoo!" heard as "Yahoo!" stays so.
    static func merging(_ spotted: [SpottedTerm], into heard: [HeardWord]) -> [HeardWord] {
        var words = heard
        for spotting in spotted {
            let (term, first, last) = (spotting.words, spotting.words.first!.first, spotting.last)
            let replaced = words.filter { $0.sounds(within: first, last) }
            let heard = replaced.last.map(\.trailingPunctuation) ?? ""
            let spelled = term.last!.trailingPunctuation
            let said = term.dropLast() + [term.last!.ending(with: String(heard.dropFirst(heard.commonPrefix(with: spelled).count)))]
            words.removeAll { $0.sounds(within: first, last) }
            let at = words.firstIndex { $0.first > first } ?? words.endIndex
            words.insert(contentsOf: said, at: at)
        }
        return words
    }

    private var trailingPunctuation: String {
        String(text.reversed().prefix { $0.isPunctuation }.reversed())
    }

    private func ending(with punctuation: String) -> HeardWord {
        HeardWord(text: text + punctuation, first: first, last: last, confidence: confidence)
    }
}

/// A term the spotter heard: its words, each timed as a TDT word is, and the frame at `last`,
/// the last it was heard over, which its last piece may be held to past its last word's time.
struct SpottedTerm: Equatable, Sendable {
    let words: [HeardWord]
    let last: Int

    /// The words of this term that sound from `cut` on, by the rule TDT words are cut by, or nil
    /// where none do.
    func sounding(after cut: Int) -> SpottedTerm? {
        let kept = words.filter { HeardWord.sounds(from: $0.first, to: $0.last, after: cut) }
        return kept.isEmpty ? nil : SpottedTerm(words: kept, last: last)
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
