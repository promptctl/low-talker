import CoreML
import Foundation

/// The gate classifier: a small network trained for the gate's own question, whether the
/// loudest sound in a tenth of a second is speech. scripts/gate-classifier/train trained the
/// bundled model on the audio scripts/gate-classifier/manifest.tsv names (r8,
/// low-speech-gate-lss.wfn). It reads the frame with 0.2 s either side, raw: the scaling to
/// the frame's peak is inside the model.
///
/// [LAW:effects-at-boundaries] Core ML is reached here and nowhere else in the gate; the
/// gate is tested against verdicts of its own making.
struct GateClassifier: Discriminator, @unchecked Sendable {
    let lookbehind = AudioClip.sampleCount(for: 0.2)
    let lookahead = AudioClip.sampleCount(for: 0.2)
    /// The score at or above which a frame is speech: above every ESC-50 clap, cough and knock
    /// frame r8 scored, alone and beside speech (low-speech-gate-lss.96s), which keeps 51 of the
    /// bench's 56 loudest syllables. A model trained again brings its own.
    static let threshold: Float = 0.957

    /// `@unchecked Sendable`: Core ML predicts on one model from many threads at once, and each
    /// utterance asks from its own actor; nothing here mutates after the load.
    private let model: MLModel
    private let input: Int

    /// Loads the bundled model onto the CPU: the Neural Engine is Whisper's.
    init() async throws {
        guard let package = Bundle.module.url(forResource: "GateClassifier", withExtension: "mlpackage") else {
            throw GateClassifierError.notBundled
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: try await MLModel.compileModel(at: package), configuration: configuration)
        input = lookbehind + Utterance.frameCount + lookahead
        let shape = model.modelDescription.inputDescriptionsByName["samples"]?.multiArrayConstraint?.shape
        guard shape == [1, NSNumber(value: input)] else { throw GateClassifierError.shape(shape) }
    }

    func verdict(_ window: ArraySlice<Float>) throws -> Verdict {
        let samples = try MLMultiArray(shape: [1, NSNumber(value: input)], dataType: .float32)
        let pointer = samples.dataPointer.assumingMemoryBound(to: Float.self)
        for (index, sample) in window.enumerated() {
            pointer[index] = sample
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["samples": samples]))
        guard let score = output.featureValue(for: "speech")?.multiArrayValue?[0].floatValue else { throw GateClassifierError.noScore }
        return score >= Self.threshold ? .speech : .other
    }
}

/// Why the gate classifier could not load or answer: each is a build or model fault, never the audio's.
enum GateClassifierError: Error, CustomStringConvertible {
    case notBundled
    case shape([NSNumber]?)
    case noScore

    var description: String {
        switch self {
        case .notBundled: "GateClassifier.mlpackage is not in LowTalkerCore's resources"
        case .shape(let shape): "the gate classifier takes samples shaped \(shape.map { "\($0)" } ?? "unnamed"), not one frame and its context"
        case .noScore: "the gate classifier answered without a `speech` score"
        }
    }
}
