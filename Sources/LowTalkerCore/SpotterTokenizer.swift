import Foundation

/// The spotter's vocabulary: the pieces of the CTC model's tokenizer, read from its
/// `tokenizer.json`, and every way they spell a term.
///
/// A term is spelled as the Metaspace pre-tokenizer writes it, `▁` before each word, and then as
/// every sequence of pieces that writes exactly that, not only the one its byte-pair merges would
/// pick. A CTC model emits whichever pieces it hears, and a name it has never seen is heard in
/// pieces its spelling's merges would not choose. The paper's alternatives sampled by BPE dropout
/// (Andrusenko et al. 2024, Sec. 4.3) are samples of these.
///
/// [LAW:single-enforcer] The one judge of whether a vocabulary can be told to Parakeet: the
/// config's check and the graph the spotter searches both spell terms here, so a term the
/// config accepted is the term the spotter hears. The file's normalizer (`Precompiled`) is not
/// run: the vocabulary's characters are A-Z, a-z and `! ' , . ?`, which it leaves as they are,
/// and a term no sequence of pieces spells is refused rather than normalized into one.
public struct SpotterTokenizer: Sendable {
    private let ids: [String: Int]
    private let longest: Int
    /// The ids of the pieces that start a word, so a greedy reading of the frames knows where
    /// its words begin.
    let wordStarts: Set<Int>

    /// The mark a piece that starts a word begins with.
    static let wordStart: Character = "\u{2581}"

    public init(json: Data) throws(PromptsUnavailable) {
        struct File: Decodable {
            struct Model: Decodable {
                let vocab: [String: Int]
            }
            let model: Model
        }
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: json) } catch {
            throw PromptsUnavailable(why: "the spotter's tokenizer.json has no vocabulary of pieces to ids: \(error)")
        }
        guard let longest = file.model.vocab.keys.map(\.count).max() else {
            throw PromptsUnavailable(why: "the spotter's tokenizer.json has no pieces")
        }
        // [LAW:parse-dont-validate] Every id is a class of the head's rows, so the search reads
        // a row at any piece it spells.
        if let (piece, id) = file.model.vocab.first(where: { !(0..<SpotterClasses.blank).contains($0.value) }) {
            throw PromptsUnavailable(why: "the spotter's tokenizer.json gives \(piece) id \(id), outside the head's \(SpotterClasses.blank) pieces")
        }
        ids = file.model.vocab
        self.longest = longest
        wordStarts = Set(file.model.vocab.filter { $0.key.first == Self.wordStart }.values)
    }

    /// Each term's spellings, in the vocabulary's order, or the refusal of the first term no
    /// sequence of pieces spells.
    public func terms(_ vocabulary: Vocabulary) throws(VocabularyError) -> [SpelledTerm] {
        try vocabulary.terms.map { term throws(VocabularyError) in try spell(term) }
    }

    /// Every piece that writes the term from each character of it on. Refused, naming the
    /// character of the term, never the `▁` written before a word, where the pieces can write
    /// the term only up to that character.
    func spell(_ term: Vocabulary.Term) throws(VocabularyError) -> SpelledTerm {
        let written = Array(term.text.split(whereSeparator: \.isWhitespace).map { String(Self.wordStart) + $0 }.joined())
        var arcs: [[SpelledTerm.Arc]] = Array(repeating: [], count: written.count)
        var reached = Array(repeating: false, count: written.count + 1)
        reached[0] = true
        for start in written.indices where reached[start] {
            for end in start + 1...min(written.count, start + longest) {
                let piece = String(written[start..<end])
                // A piece carries `▁` only first, so none spans a word's start.
                guard let id = ids[piece], !piece.dropFirst().contains(Self.wordStart) else { continue }
                arcs[start].append(SpelledTerm.Arc(id: id, to: end, startsWord: written[start] == Self.wordStart))
                reached[end] = true
            }
        }
        guard reached[written.count] else {
            let stuck = reached.lastIndex(of: true)!
            throw .unspellable(term: term.text, piece: String(written[stuck...].first { $0 != Self.wordStart }!))
        }
        return SpelledTerm(term: term, arcs: arcs)
    }
}

/// A vocabulary term as every sequence of the spotter's pieces that writes it: from each
/// position in the term as written, `▁` before each word, the pieces that start there and where
/// each ends. The term is written once a path reaches its last position.
public struct SpelledTerm: Hashable, Sendable {
    public let term: Vocabulary.Term
    let arcs: [[Arc]]

    struct Arc: Hashable, Sendable {
        let id: Int
        /// The position the piece ends at, and the next starts from.
        let to: Int
        let startsWord: Bool
    }

    /// The position a path that has written the whole term is at.
    var end: Int { arcs.count }

    /// The term's words as written, one for each piece that starts a word.
    var words: [String] {
        term.text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
