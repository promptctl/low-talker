/// Parakeet TDT's three networks, as the greedy decoder drives them: the encoder over a window
/// of audio, the predictor over the last token, and the joint over one frame and one prediction.
///
/// [LAW:effects-at-boundaries] The port the decoder is written against. `CoreMLParakeet` is
/// the one adapter, over FluidInference's Core ML conversion; a test hands the decoder a
/// scripted network instead, so every decision the decoder makes is tested with no model.
public protocol ParakeetNetwork: Sendable {
    /// The predictor's state before any token: zeros, of the predictor's own size.
    var startState: PredictorState { get }
    /// `samples`, at most `ParakeetWindow.samples` of them at 16 kHz, as encoder frames of
    /// 80 ms each.
    func encode(_ samples: ArraySlice<Float>) throws -> EncodedWindow
    /// The predictor's output after `token`, from `state`, and the state it leaves.
    func predict(_ token: Int, from state: PredictorState) throws -> (Prediction, PredictorState)
    /// The joint's most likely token, its probability, and the index of its most likely
    /// duration, at `frame` after `prediction`.
    func joint(_ frame: EncodedFrame, _ prediction: Prediction) throws -> JointStep
}

/// What TDT v3's networks are, as their published configuration states it (nvidia/
/// parakeet-tdt-0.6b-v3 config.json) and FluidInference's Core ML models take them.
public enum ParakeetWindow {
    /// The most audio one encoder pass takes: the Preprocessor's fixed input, 15 s at 16 kHz.
    public static let samples = 240_000
    /// Samples per encoder frame: a mel hop of 160 samples, subsampled 8 times, so 80 ms.
    public static let frameSamples = 1_280
    /// Frame counts the joint's duration indices stand for (`durations`).
    public static let durations = [0, 1, 2, 3, 4]
    /// The token the joint emits for "nothing here", one past the vocabulary's last piece, and
    /// the predictor's start symbol (`blank_token_id`).
    public static let blank = 8_192
    /// The most tokens greedy decoding emits at one frame before it moves on
    /// (`max_symbols_per_step`).
    public static let maxSymbolsPerFrame = 10
}

/// One window's encoder output: a frame per 80 ms of the audio the window held.
public struct EncodedWindow: Sendable {
    public let frames: [EncodedFrame]

    public init(frames: [EncodedFrame]) {
        self.frames = frames
    }
}

/// One encoder frame's features.
public struct EncodedFrame: Sendable, Equatable {
    public let features: [Float]

    public init(features: [Float]) {
        self.features = features
    }
}

/// The predictor's output, which the joint reads beside each frame.
public struct Prediction: Sendable, Equatable {
    public let features: [Float]

    public init(features: [Float]) {
        self.features = features
    }
}

/// The predictor's recurrent state, carried from one token to the next.
public struct PredictorState: Sendable, Equatable {
    public let hidden: [Float]
    public let cell: [Float]

    public init(hidden: [Float], cell: [Float]) {
        self.hidden = hidden
        self.cell = cell
    }
}

/// The joint's decision at one frame.
public struct JointStep: Sendable, Equatable {
    public let token: Int
    public let probability: Float
    public let duration: Int

    public init(token: Int, probability: Float, duration: Int) {
        self.token = token
        self.probability = probability
        self.duration = duration
    }
}
