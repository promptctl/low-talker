import CoreML
import Foundation

/// nvidia/parakeet-tdt_ctc-110m's encoder and CTC head as the spotter's network, as FluidInference
/// converts them: `Preprocessor.mlmodelc` (mel front end and encoder, its normalization masked to
/// the audio's length) from parakeet-tdt-ctc-110m-coreml, and `CtcHead.mlmodelc` from
/// parakeet-ctc-110m-coreml, driven through the inputs and outputs their published `metadata.json`
/// and `model.mil` declare.
///
/// [LAW:effects-at-boundaries] The one adapter between `MLMultiArray` and the spotter's rows.
/// [LAW:no-shared-mutable-globals] `@unchecked Sendable` because `MLModel` is a class the
/// compiler cannot vouch for; the engine's `EngineTurns` runs one pass at a time over it.
struct CoreMLSpotter: SpotterNetwork, @unchecked Sendable {
    private let encoder: MLModel
    private let head: MLModel

    /// Loads the encoder from `encoder` and the head from `head`, and refuses either whose
    /// interface is not the one written against. [LAW:parse-dont-validate]
    init(encoder: URL, head: URL, computeUnits: MLComputeUnits = .all) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        func load(_ file: URL, _ interface: ParakeetInterface) async throws -> MLModel {
            let model = try await MLModel.load(contentsOf: file, configuration: configuration)
            try interface.check(file.lastPathComponent, model.modelDescription.interface)
            return model
        }
        self.encoder = try await load(encoder.appending(path: ParakeetModel.spotterEncoder), ParakeetInterface.spotterEncoder)
        self.head = try await load(head.appending(path: ParakeetModel.spotterHead), ParakeetInterface.spotterHead)
    }

    func logProbabilities(_ samples: ArraySlice<Float>) throws -> [[Float]] {
        precondition(samples.count <= ParakeetWindow.samples, "a window is at most \(ParakeetWindow.samples) samples")
        let audio = try MLMultiArray(shape: [1, ParakeetWindow.samples as NSNumber], dataType: .float32)
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.initialize(repeating: 0)
            _ = buffer.update(fromContentsOf: samples)
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = samples.count as NSNumber
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio_signal": audio, "audio_length": length]))
        guard let features = encoded.featureValue(for: "encoder")?.multiArrayValue, let count = encoded.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue else {
            throw ParakeetLoadError.interface(model: ParakeetModel.spotterEncoder, "no encoder or encoder_length output")
        }
        let frames = features.shape[2].intValue
        guard (0...frames).contains(count) else {
            throw ParakeetLoadError.interface(model: ParakeetModel.spotterEncoder, "it says \(count) frames of the \(frames) it returns are speech")
        }
        let output = try head.prediction(from: MLDictionaryFeatureProvider(dictionary: ["encoder_output": features]))
        guard let rows = output.featureValue(for: "ctc_logits")?.multiArrayValue, rows.dataType == .float32 else {
            throw ParakeetLoadError.interface(model: ParakeetModel.spotterHead, "no Float32 ctc_logits output")
        }
        let (along, by) = (rows.strides[1].intValue, rows.strides[2].intValue)
        return rows.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            (0..<count).map { frame in (0..<SpotterClasses.count).map { buffer[frame * along + $0 * by] } }
        }
    }
}

extension ParakeetInterface {
    /// The spotter's encoder's interface, as parakeet-tdt-ctc-110m-coreml's `metadata.json`
    /// states it.
    static let spotterEncoder = ParakeetInterface(features: [
        "audio_signal": Feature(type: .float32, shape: [1, ParakeetWindow.samples]),
        "audio_length": Feature(type: .int32, shape: [1]),
        "encoder": Feature(type: .float32, shape: [1, 512, 188]),
        "encoder_length": Feature(type: .int32, shape: [1]),
    ])

    /// The spotter's head's interface, as parakeet-ctc-110m-coreml's `metadata.json` states it.
    static let spotterHead = ParakeetInterface(features: [
        "encoder_output": Feature(type: .float32, shape: [1, 512, 188]),
        "ctc_logits": Feature(type: .float32, shape: [1, 188, SpotterClasses.count]),
    ])
}
