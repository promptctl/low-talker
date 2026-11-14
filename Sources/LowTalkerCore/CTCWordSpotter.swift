import Foundation

/// Finds a vocabulary's terms in a CTC model's frames, written from Andrusenko et al. 2024,
/// "Fast Context-Biasing for CTC and Transducer ASR models with CTC-based Word Spotter"
/// (arXiv 2406.07096): Algorithm 1 searches the frames for each term along a graph of its
/// pieces (Sec. 2.1, Fig. 3), and a term found is kept only where it scores above the greedy
/// reading of the same frames (Fig. 2). Every frame is one row of log-probabilities, one per
/// class, the blank last.
///
/// The graph is each term's every spelling (`SpelledTerm`), not one spelling of each in a
/// prefix tree as the paper draws it. The CTC topology of Fig. 3 is the same at every arc, so the
/// search applies it: a piece may be held over frames, a blank may follow it and be held, and the
/// next piece follows either, except that a piece repeating the last needs a blank between, as
/// CTC reads two frames of one piece as one.
///
/// [LAW:effects-at-boundaries] Pure: the frames are handed in, so every rule here is tested
/// against a matrix written by hand.
struct CTCWordSpotter {
    let terms: [SpelledTerm]
    let blank: Int
    /// The classes whose piece starts a word.
    let wordStarts: Set<Int>

    /// The values the paper tuned on its development set (Sec. 3.6) for nvidia's 114M hybrid
    /// FastConformer with 1024 BPE pieces, the model this spotter's encoder and head are.
    static let termWeight: Float = 3.0
    static let greedyWeight: Float = 0.5
    static let blankSkip: Float = log(0.8)
    static let tokenSkip: Float = log(0.001)
    static let beam: Float = 7.0

    /// A term found in the frames: the pieces of the spelling it was found in, each with the frame
    /// it was entered on and its log-probability there, the frame it ended on, and its score.
    struct Hit: Equatable {
        let term: SpelledTerm
        let path: [Step]
        let end: Int
        let score: Float

        struct Step: Equatable {
            let arc: SpelledTerm.Arc
            let frame: Int
            let logProbability: Float
        }

        var start: Int { path[0].frame }
    }

    /// What one search found, and how many of the found were refused.
    struct Spotting: Equatable {
        /// Non-overlapping hits, earliest first, each scoring above the greedy reading it
        /// overlaps.
        let hits: [Hit]
        /// The terms the search ended on, every end frame counted.
        let candidates: Int
        /// Hits the greedy reading outscored.
        let outscored: Int
    }

    /// One path through a term's spellings: where in the term it is, the piece it entered there
    /// on, whether its last frame was a blank, and what it has scored.
    private struct Hypothesis {
        let state: State
        let score: Float
        let path: [Hit.Step]
    }

    private struct State: Hashable {
        let term: Int
        let position: Int
        let token: Int
        let blank: Bool
    }

    func spot(_ frames: [[Float]]) -> Spotting {
        var active: [Hypothesis] = []
        var found: [Hit] = []
        for (frame, row) in frames.enumerated() {
            var next: [State: Hypothesis] = [:]
            func offer(_ state: State, _ score: Float, _ path: [Hit.Step]) {
                if score > next[state]?.score ?? -.infinity { next[state] = Hypothesis(state: state, score: score, path: path) }
            }
            func enter(_ arc: SpelledTerm.Arc, of term: Int, after hypothesis: Hypothesis?) {
                let step = Hit.Step(arc: arc, frame: frame, logProbability: row[arc.id])
                offer(State(term: term, position: arc.to, token: arc.id, blank: false), (hypothesis?.score ?? 0) + row[arc.id] + Self.termWeight, (hypothesis?.path ?? []) + [step])
            }
            // A term may start on any frame, unless the frame is surely blank (Alg. 1 l. 5-12).
            if row[blank] <= Self.blankSkip {
                for (index, term) in terms.enumerated() {
                    for arc in term.arcs[0] where row[arc.id] >= Self.tokenSkip { enter(arc, of: index, after: nil) }
                }
            }
            for hypothesis in active {
                let state = hypothesis.state
                // A piece held over more frames, a blank after it, or a blank held.
                if !state.blank {
                    offer(state, hypothesis.score + row[state.token] + Self.termWeight, hypothesis.path)
                }
                offer(State(term: state.term, position: state.position, token: state.token, blank: true), hypothesis.score + row[blank], hypothesis.path)
                let term = terms[state.term]
                guard state.position < term.end else { continue }
                for arc in term.arcs[state.position] where state.blank || arc.id != state.token {
                    enter(arc, of: state.term, after: hypothesis)
                }
            }
            // State pruning keeps the best path to each state; the beam drops paths far behind
            // the frame's best (Alg. 1 l. 24).
            let best = next.values.map(\.score).max() ?? 0
            active = next.values.filter { $0.score >= best - Self.beam }
            for hypothesis in active where !hypothesis.state.blank && hypothesis.state.position == terms[hypothesis.state.term].end {
                found.append(Hit(term: terms[hypothesis.state.term], path: hypothesis.path, end: frame, score: hypothesis.score))
            }
        }
        // Of candidates that overlap, the best scoring is kept (Alg. 1 l. 27).
        var kept: [Hit] = []
        for hit in found.sorted(by: { $0.score > $1.score }) where !kept.contains(where: { $0.start <= hit.end && hit.start <= $0.end }) {
            kept.append(hit)
        }
        let greedy = GreedyReading(frames, blank: blank, wordStarts: wordStarts)
        let heard = kept.filter { $0.score > greedy.score(from: $0.start, to: $0.end) }
        return Spotting(hits: heard.sorted { $0.start < $1.start }, candidates: found.count, outscored: kept.count - heard.count)
    }
}

extension CTCWordSpotter.Hit {
    /// The term's words as heard, timed in samples from `start`, the sample frame 0 starts at:
    /// each from the frame its first piece was entered on to the frame its last piece was entered
    /// on, as a TDT word is timed, except the last, which runs to the frame the hit ended on, so
    /// the term spans every frame it was heard over. Each is as sure as the product of its
    /// pieces' probabilities on the frames they were entered on.
    func words(from start: Int) throws(ParakeetReadingError) -> [HeardWord] {
        var words: [HeardWord] = []
        var spoken = term.words.makeIterator()
        for step in path {
            let sample = start + step.frame * ParakeetWindow.frameSamples
            let sure = try ParakeetVocabulary.sure(exp(step.logProbability), term.term.text)
            if step.arc.startsWord || words.isEmpty {
                words.append(HeardWord(text: " " + (spoken.next() ?? ""), first: sample, last: sample, confidence: sure))
            } else {
                let word = words.removeLast()
                words.append(HeardWord(text: word.text, first: word.first, last: sample, confidence: word.confidence * sure))
            }
        }
        let last = words.removeLast()
        return words + [HeardWord(text: last.text, first: last.first, last: start + end * ParakeetWindow.frameSamples, confidence: last.confidence)]
    }
}

/// The frames read greedily, the most likely class on each, as words: a word starts at a piece
/// that starts one. Each word scores the sum, over its frames that are not blank, of the
/// frame's log-probability and `greedyWeight`, as the paper's greedy words do (Sec. 2.1; its
/// Fig. 2 scores are positive, so the weight is added, not multiplied).
struct GreedyReading {
    private var words: [(start: Int, end: Int, score: Float)] = []

    init(_ frames: [[Float]], blank: Int, wordStarts: Set<Int>) {
        var previous = blank
        for (frame, row) in frames.enumerated() {
            let token = row.indices.max { row[$0] < row[$1] }!
            defer { previous = token }
            guard token != blank else { continue }
            let score = row[token] + CTCWordSpotter.greedyWeight
            if token != previous, wordStarts.contains(token) || words.isEmpty {
                words.append((frame, frame, score))
            } else {
                words[words.count - 1].end = frame
                words[words.count - 1].score += score
            }
        }
    }

    /// The greedy words' score over the frames from `start` to `end`: every word with a frame
    /// among them counts whole.
    func score(from start: Int, to end: Int) -> Float {
        words.filter { $0.start <= end && start <= $0.end }.reduce(0) { $0 + $1.score }
    }
}
