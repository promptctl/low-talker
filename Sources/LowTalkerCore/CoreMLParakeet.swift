import CoreML
import Foundation

/// FluidInference's Core ML conversion of Parakeet TDT v3 as the decoder's network: four
/// models (Preprocessor, Encoder, Decoder, JointDecision), driven through the inputs and outputs
/// their published `metadata.json` and `model.mil` declare.
///
/// [LAW:effects-at-boundaries] The one adapter between `MLMultiArray` and the decoder's arrays.
/// [LAW:no-shared-mutable-globals] `@unchecked Sendable` because `MLModel` is a class the
/// compiler cannot vouch for; the engine's `EngineTurns` runs one pass at a time over it.
struct CoreMLParakeet: ParakeetNetwork, @unchecked Sendable {
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel

    /// Loads the four models from `folder` and refuses any whose interface is not the one
    /// written against, naming what differs, before a pass can meet it. [LAW:parse-dont-validate]
    init(folder: URL, computeUnits: MLComputeUnits = .all) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        func load(_ file: String) async throws -> MLModel {
            let model = try await MLModel.load(contentsOf: folder.appending(path: file), configuration: configuration)
            try ParakeetInterface.published[file]!.check(file, model.modelDescription.interface)
            return model
        }
        preprocessor = try await load(ParakeetModel.preprocessor)
        encoder = try await load(ParakeetModel.encoder)
        decoder = try await load(ParakeetModel.decoder)
        joint = try await load(ParakeetModel.joint)
    }

    var startState: PredictorState {
        let zeros = [Float](repeating: 0, count: ParakeetInterface.stateCount)
        return PredictorState(hidden: zeros, cell: zeros)
    }

    func encode(_ samples: ArraySlice<Float>) throws -> EncodedWindow {
        precondition(samples.count <= ParakeetWindow.samples, "a window is at most \(ParakeetWindow.samples) samples")
        let audio = try MLMultiArray(shape: [1, ParakeetWindow.samples as NSNumber], dataType: .float32)
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.initialize(repeating: 0)
            _ = buffer.update(fromContentsOf: samples)
        }
        let mel = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": audio,
            "audio_length": try Self.ints([samples.count]),
        ]))
        // The Preprocessor's outputs are the Encoder's inputs by name.
        let encoded = try encoder.prediction(from: mel)
        let features = try Self.array("encoder", of: encoded)
        let count = try Self.array("encoder_length", of: encoded)[0].intValue
        let frames = features.shape[2].intValue
        guard (0...frames).contains(count) else {
            throw ParakeetLoadError.interface(model: ParakeetModel.encoder, "it says \(count) frames of the \(frames) it returns are speech")
        }
        let (dimension, along) = (features.strides[1].intValue, features.strides[2].intValue)
        let width = features.shape[1].intValue
        return try Self.floats(features) { buffer in
            EncodedWindow(frames: (0..<count).map { frame in
                EncodedFrame(features: (0..<width).map { buffer[$0 * dimension + frame * along] })
            })
        }
    }

    func predict(_ token: Int, from state: PredictorState) throws -> (Prediction, PredictorState) {
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": try Self.ints([token], shape: [1, 1]),
            "target_length": try Self.ints([1]),
            "h_in": try Self.floats(state.hidden, shape: ParakeetInterface.stateShape),
            "c_in": try Self.floats(state.cell, shape: ParakeetInterface.stateShape),
        ]))
        return (
            Prediction(features: try Self.values(Self.array("decoder", of: output))),
            PredictorState(hidden: try Self.values(Self.array("h_out", of: output)), cell: try Self.values(Self.array("c_out", of: output)))
        )
    }

    func joint(_ frame: EncodedFrame, _ prediction: Prediction) throws -> JointStep {
        let output = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": try Self.floats(frame.features, shape: [1, frame.features.count, 1]),
            "decoder_step": try Self.floats(prediction.features, shape: [1, prediction.features.count, 1]),
        ]))
        return JointStep(
            token: try Self.array("token_id", of: output)[0].intValue,
            probability: try Self.array("token_prob", of: output)[0].floatValue,
            duration: try Self.array("duration", of: output)[0].intValue
        )
    }

    private static func array(_ name: String, of output: any MLFeatureProvider) throws -> MLMultiArray {
        guard let array = output.featureValue(for: name)?.multiArrayValue else {
            throw ParakeetLoadError.interface(model: name, "no multi-array output named \(name)")
        }
        return array
    }

    private static func ints(_ values: [Int], shape: [Int]? = nil) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: (shape ?? [values.count]).map { $0 as NSNumber }, dataType: .int32)
        for (index, value) in values.enumerated() { array[index] = value as NSNumber }
        return array
    }

    private static func floats(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { $0 as NSNumber }, dataType: .float32)
        let strides = array.strides.map(\.intValue)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for (index, value) in values.enumerated() { buffer[offset(of: index, shape: shape, strides: strides)] = value }
        }
        return array
    }

    /// Where the element at `index`, counting in row-major order, sits in a buffer laid out by
    /// `strides`: Core ML may pad an axis, so index and offset can differ.
    private static func offset(of index: Int, shape: [Int], strides: [Int]) -> Int {
        var rest = index
        var offset = 0
        for axis in shape.indices.reversed() {
            offset += (rest % shape[axis]) * strides[axis]
            rest /= shape[axis]
        }
        return offset
    }

    /// A Float32 output's buffer, read by `body`; any other element type is refused rather
    /// than reinterpreted.
    private static func floats<T>(_ array: MLMultiArray, _ body: (UnsafeBufferPointer<Float>) -> T) throws -> T {
        guard array.dataType == .float32 else {
            throw ParakeetLoadError.interface(model: "\(array.shape)", "an output is \(array.dataType.rawValue), not Float32")
        }
        return array.withUnsafeBufferPointer(ofType: Float.self, body)
    }

    /// A Float32 output's elements in index order, whatever its strides.
    private static func values(_ array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        return try floats(array) { buffer in
            (0..<shape.reduce(1, *)).map { buffer[offset(of: $0, shape: shape, strides: strides)] }
        }
    }
}

extension MLModelDescription {
    /// Each multi-array feature's element type and shape, by name, inputs and outputs alike.
    var interface: ParakeetInterface.Features {
        let features = inputDescriptionsByName.merging(outputDescriptionsByName) { input, _ in input }
        return features.compactMapValues { feature in
            feature.multiArrayConstraint.map { ParakeetInterface.Feature(type: $0.dataType, shape: $0.shape.map(\.intValue)) }
        }
    }
}

/// The inputs and outputs of the published models, as the decoder is written against them.
///
/// [LAW:single-enforcer] Checked once per model at load; past it, the adapter reads features by
/// these names without asking again.
struct ParakeetInterface: Equatable {
    struct Feature: Equatable, CustomStringConvertible {
        let type: MLMultiArrayDataType
        /// Empty where the model leaves the shape unstated.
        let shape: [Int]

        var description: String { "\(type == .float32 ? "Float32" : type == .int32 ? "Int32" : "type \(type.rawValue)") \(shape)" }
    }

    typealias Features = [String: Feature]

    let features: Features

    static let stateShape = [2, 1, 640]
    static let stateCount = stateShape.reduce(1, *)

    static let published: [String: ParakeetInterface] = [
        ParakeetModel.preprocessor: ParakeetInterface(features: [
            "audio_signal": Feature(type: .float32, shape: [1, ParakeetWindow.samples]),
            "audio_length": Feature(type: .int32, shape: [1]),
            "mel": Feature(type: .float32, shape: [1, 128, 1501]),
            "mel_length": Feature(type: .int32, shape: [1]),
        ]),
        ParakeetModel.encoder: ParakeetInterface(features: [
            "mel": Feature(type: .float32, shape: [1, 128, 1501]),
            "mel_length": Feature(type: .int32, shape: [1]),
            "encoder": Feature(type: .float32, shape: [1, 1024, 188]),
            "encoder_length": Feature(type: .int32, shape: [1]),
        ]),
        ParakeetModel.decoder: ParakeetInterface(features: [
            "targets": Feature(type: .int32, shape: [1, 1]),
            "target_length": Feature(type: .int32, shape: [1]),
            "h_in": Feature(type: .float32, shape: stateShape),
            "c_in": Feature(type: .float32, shape: stateShape),
            "decoder": Feature(type: .float32, shape: [1, 640, 1]),
            "h_out": Feature(type: .float32, shape: stateShape),
            "c_out": Feature(type: .float32, shape: stateShape),
        ]),
        ParakeetModel.joint: ParakeetInterface(features: [
            "encoder_step": Feature(type: .float32, shape: [1, 1024, 1]),
            "decoder_step": Feature(type: .float32, shape: [1, 640, 1]),
            "token_id": Feature(type: .int32, shape: [1, 1, 1]),
            "token_prob": Feature(type: .float32, shape: [1, 1, 1]),
            "duration": Feature(type: .int32, shape: [1, 1, 1]),
        ]),
    ]

    /// Refuses `found` unless it has every feature this names, of its type and, where `found`
    /// states one, its shape. Extra features are not refused: the decoder never reads them.
    func check(_ model: String, _ found: Features) throws(ParakeetLoadError) {
        for (name, feature) in features.sorted(by: { $0.key < $1.key }) {
            guard let other = found[name] else { throw .interface(model: model, "it has no feature \(name)") }
            guard other.type == feature.type, other.shape.isEmpty || other.shape == feature.shape else {
                throw .interface(model: model, "\(name) is \(other) where the decoder reads \(feature)")
            }
        }
    }
}
