/// Greedy decoding of a token-and-duration transducer, written from Xu et al. 2023,
/// "Efficient Sequence Transduction by Jointly Predicting Tokens and Durations"
/// (arXiv 2304.06795).
///
/// A TDT joint predicts, at each encoder frame, a token and how many frames that token
/// covers. Greedy decoding takes the likelier of each: a token other than the blank is
/// emitted at the frame and fed to the predictor, and the frame moves on by the duration. A
/// duration of 0 lets several tokens land on one frame; a blank's 0 would never move, so a
/// blank always advances at least one frame, and a frame that has emitted
/// `maxSymbolsPerFrame` tokens is left.
///
/// [LAW:effects-at-boundaries] The network is a port, so every rule here is tested against a
/// scripted one. The predictor's state and its last prediction carry across the windows of
/// one pass: a window boundary is where the encoder's input is cut, not where speech stops.
struct TDTDecoding {
    private let network: any ParakeetNetwork
    private var prediction: Prediction
    private var state: PredictorState
    private(set) var tokens: [EmittedToken] = []
    private(set) var facts = ParakeetPassFacts()

    /// A token the joint emitted, at the sample its frame starts, counted from the pass's
    /// first sample.
    struct EmittedToken: Equatable, Sendable {
        let id: Int
        let sample: Int
        let probability: Float
    }

    /// Starts from the blank as the start symbol, with the predictor's state at rest.
    init(network: any ParakeetNetwork) throws {
        self.network = network
        (prediction, state) = try network.predict(ParakeetWindow.blank, from: network.startState)
    }

    /// Decodes one window's frames, its first frame at sample `start` of the pass.
    mutating func decode(_ window: EncodedWindow, from start: Int) throws {
        facts.windows += 1
        facts.frames += window.frames.count
        var frame = 0
        var emittedHere = 0
        while frame < window.frames.count {
            let step = try network.joint(window.frames[frame], prediction)
            guard ParakeetWindow.durations.indices.contains(step.duration) else {
                throw ParakeetReadingError.durationOutOfRange(step.duration)
            }
            var advance = ParakeetWindow.durations[step.duration]
            if step.token == ParakeetWindow.blank {
                facts.blanks += 1
                advance = max(advance, 1)
            } else {
                tokens.append(EmittedToken(id: step.token, sample: start + frame * ParakeetWindow.frameSamples, probability: step.probability))
                facts.tokens += 1
                (prediction, state) = try network.predict(step.token, from: state)
                emittedHere += 1
                if advance == 0, emittedHere == ParakeetWindow.maxSymbolsPerFrame {
                    facts.forcedAdvances += 1
                    advance = 1
                }
            }
            frame += advance
            if advance > 0 { emittedHere = 0 }
        }
    }
}

/// What one Parakeet pass did, as its log line says it.
///
/// [LAW:nothing-unseen] A pass that heard nothing and one that never ran differ here: every
/// pass that ran logs its counts, zeros included.
struct ParakeetPassFacts: Equatable, Sendable, CustomStringConvertible {
    /// Samples handed to the encoder, from the lead-in before the cut to the pass's end.
    var samples = 0
    var windows = 0
    var frames = 0
    var blanks = 0
    /// Tokens the joint emitted.
    var tokens = 0
    /// Frames left because they had emitted `maxSymbolsPerFrame` tokens.
    var forcedAdvances = 0

    var description: String {
        "parakeet pass: \(samples) samples in \(windows) windows, \(frames) frames, \(tokens) tokens, \(blanks) blanks, \(forcedAdvances) forced advances"
    }
}
