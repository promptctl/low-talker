import Foundation

/// A speech model, named the way a config file, a bench flag and a store's manifests
/// spell it, and carrying the engine that hears through it.
///
/// [LAW:types-are-the-program] [LAW:parse-dont-validate] The name is parsed once, here,
/// into the engine it belongs to; nothing downstream tells engines apart by reading the
/// string again. A name in Parakeet's closed set is Parakeet's; any other path step is a
/// folder in the whisperkit-coreml repo, which grows, so that side stays a name.
public enum Model: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    case whisperKit(WhisperKitModel)
    case parakeet(ParakeetModel)

    public init?(rawValue: String) {
        if let parakeet = ParakeetModel(rawValue: rawValue) {
            self = .parakeet(parakeet)
        } else if let whisperKit = WhisperKitModel(rawValue: rawValue) {
            self = .whisperKit(whisperKit)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .whisperKit(let model): model.rawValue
        case .parakeet(let model): model.rawValue
        }
    }

    /// A literal is a name the author vouches for; one that is not a model name is a
    /// bug in the source, and traps where it is written.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)!
    }

    public var description: String { rawValue }

    /// [LAW:single-enforcer] What a name may be is this type's rule, so the sentence a
    /// bad one earns is written here rather than by whatever is parsing it. The
    /// synthesised decoder's sentence names Swift types, which mean nothing to someone
    /// editing a config file.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let model = Model(rawValue: raw) else {
            throw decoder.fault("\"\(raw)\" is not a model name: one folder in the model repo, such as base.en, or \(ParakeetModel.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self = model
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The engine's name, as the menu and the logs say it.
    public var engine: String {
        switch self {
        case .whisperKit: "WhisperKit"
        case .parakeet: "Parakeet"
        }
    }

    /// The Hugging Face repo the model's weights are published in.
    public var repo: String {
        switch self {
        case .whisperKit: "argmaxinc/whisperkit-coreml"
        case .parakeet(let model): model.repo
        }
    }

    /// The parts a store installs and records for this model. A Whisper model decodes
    /// with a tokenizer published in a repo of its own; Parakeet's vocabulary ships
    /// beside its weights, so its weights are the whole model.
    public var parts: [ModelPart] {
        switch self {
        case .whisperKit: [.weights, .tokenizer]
        case .parakeet: [.weights]
        }
    }

    /// Whisper large-v3-turbo (large-v3's encoder with a four-layer decoder) in the
    /// variant that ships a prefilled decoder context. Chosen by the bench
    /// on an M2 Max: it heard every bench fixture exactly as the plain 626 MB
    /// variant did and decoded each one sooner, while the distilled models misheard
    /// proper nouns and the small models misheard whole phrases. The numbers are in
    /// docs/engineering.md under "The latency harness".
    public static let `default`: Model = .whisperKit("large-v3-v20240930_turbo_632MB")

    /// [LAW:one-source-of-truth] The models an app bundle carries, which are the models a
    /// config may name: the default, and Parakeet beside it until the bake-off
    /// (low-engines-7ht.3) sets which ones ship. `model-tool carried` prints this list for
    /// the build, CI and the SBOM to read.
    public static let carried: [Model] = [.default, .parakeet(.tdtV3)]
}

/// A model folder name in the whisperkit-coreml repo, such as `base.en` or
/// `large-v3-v20240930_626MB`. The repo grows, so this is a name, not an enum.
///
/// [LAW:parse-dont-validate] A name is one step of a path. Every path the store
/// builds from a name stays inside the store because a name that could climb out
/// cannot be made.
public struct WhisperKitModel: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isPathStep else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)!
    }
}

/// A Parakeet model FluidInference publishes in Core ML. A closed set: the decoder is
/// written against each one's inputs and outputs, so a model this enum does not name is
/// one nothing here can hear through.
public enum ParakeetModel: String, CaseIterable, Hashable, Sendable {
    /// NVIDIA's parakeet-tdt-0.6b-v3, a FastConformer encoder with a token-and-duration
    /// transducer (TDT) decoder, converted by FluidInference.
    case tdtV3 = "parakeet-tdt-0.6b-v3"

    public var repo: String {
        switch self {
        case .tdtV3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
    }

    /// [LAW:one-source-of-truth] The files of the repo the engine loads, which are the
    /// files an install fetches: the repo also holds older and alternative conversions,
    /// about 3 GB in all. Encoder_v2 is the int8 encoder the repo added (commit 7dd20fe6)
    /// to fix token corruption in its 6-bit Encoder.
    public static let preprocessor = "Preprocessor.mlmodelc"
    public static let encoder = "Encoder_v2.mlmodelc"
    public static let decoder = "Decoder.mlmodelc"
    public static let joint = "JointDecision.mlmodelc"
    public static let vocabulary = "parakeet_v3_vocab.json"
    public static let files = [preprocessor, encoder, decoder, joint, vocabulary]
}

extension StringProtocol {
    /// One step down a relative path: it names an entry, rather than standing still
    /// (`.`), climbing out (`..`), being nothing at all, or spanning several steps.
    var isPathStep: Bool {
        !isEmpty && self != "." && self != ".." && !contains("/")
    }
}
