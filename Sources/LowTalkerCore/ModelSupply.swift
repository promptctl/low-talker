import Foundation

/// Where the app's models come from: how each is told a vocabulary, which checks a config's
/// modes in a fraction of a second, and the one the config names loaded onto the compute units,
/// which can take minutes. One port for both because both read the same models, so a vocabulary
/// is never checked against a tokenizer the engine does not have. [LAW:one-source-of-truth]
public protocol ModelSupply: Sendable {
    /// Every carried model's vocabulary check, read with no Core ML load.
    func prompting() async -> Prompting
    /// `model` resident, hearing for dictation and for the server, its waits taking `turns`.
    /// `phase` is told each step of the load as it begins.
    func load(_ model: Model, turns: EngineTurns, phase: @escaping @Sendable (LoadPhase) -> Void) async throws -> LoadedEngine
}

/// What a load is doing right now. One step, because a store this module loads is
/// already whole: the road that first installs into a store, with its own phases, is
/// `ModelInstall`'s. There is no "ready" case: the returned transcriber is that state.
public enum LoadPhase: Equatable, Sendable, CustomStringConvertible {
    /// Core ML is loading the model. The first load on a Mac, after an OS update,
    /// or after a change to the app's signing identity also specializes the model
    /// for the Neural Engine, which takes minutes.
    case loading

    public var description: String {
        switch self {
        case .loading: "loading model, minutes the first time on this Mac"
        }
    }
}

/// A model resident on the compute units: the one engine, as dictation hears through it and as
/// the server's callers do.
public struct LoadedEngine: Sendable {
    public let model: Model
    public let dictation: any Transcriber
    public let served: any Transcriber

    public init(model: Model, dictation: any Transcriber, served: any Transcriber) {
        self.model = model
        self.dictation = dictation
        self.served = served
    }

    /// `installed` loaded onto the compute units by the engine its model names.
    ///
    /// [LAW:single-enforcer] The one place a model picks its engine: the app's supply and the
    /// bench both load through here.
    public init(loading installed: InstalledModel, turns: EngineTurns) async throws {
        switch installed.model {
        case .whisperKit:
            let engine = try await WhisperKitTranscriber(installed, turns: turns)
            self.init(model: installed.model, dictation: engine, served: engine.served)
        case .parakeet:
            let engine = try await ParakeetTranscriber(installed, turns: turns)
            self.init(model: installed.model, dictation: engine, served: engine.served)
        }
    }
}

/// The model the app bundle carries, read in place: read-only, verified whole where the code
/// signature sealed it, written to never.
///
/// There is deliberately no other way to a model from here, and a bundle carrying none is a build
/// error reported where the person reads it, rather than a download: an app reaching the network
/// for its model made a development build that had shipped without one look launchable. Every
/// bundle carries its model; `make app` fills the store as scripts/sign-release does.
/// [LAW:types-are-the-program] [LAW:no-silent-failure]
public struct CarriedModel: ModelSupply {
    /// The bundle's store, or why there is none.
    private let store: Result<ModelStore, BundleCarriesNoModel>

    /// `store` is the bundle's, read once by the caller, which hands the same store to anything
    /// else that reads the carried models.
    public init(store: ModelStore?) {
        self.store = store.map(Result.success) ?? .failure(BundleCarriesNoModel())
    }

    public func prompting() async -> Prompting {
        var encoders: [Model: Result<PromptEncoder, PromptsUnavailable>] = [:]
        for model in Model.carried {
            encoders[model] = await Result { () async throws(PromptsUnavailable) in
                let installed: InstalledModel
                do { installed = try store.get().installedModel(model) } catch { throw PromptsUnavailable(why: "\(error)") }
                return try await PromptEncoder.load(installed)
            }
        }
        return Prompting(encoders)
    }

    public func load(_ model: Model, turns: EngineTurns, phase: @escaping @Sendable (LoadPhase) -> Void) async throws -> LoadedEngine {
        let installed = try store.get().installedModel(model)
        phase(.loading)
        return try await LoadedEngine(loading: installed, turns: turns)
    }
}

/// A bundle built without the model it is supposed to carry.
///
/// [LAW:no-silent-failure] Not a state this app recovers from and not one it downloads its way
/// out of: the model is put in at build time, so a bundle without one was built wrong and the only
/// thing to do about it is say so where the person running it will read it.
public struct BundleCarriesNoModel: Error, Sendable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "this build carries no model in Contents/Resources/\(ModelStore.carriedResourceName); "
            + "it was built without one. Build it with `make app`, which puts the model in"
    }
}
