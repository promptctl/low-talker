import Foundation

/// Where the app's model comes from: its tokenizer alone, which checks a config's vocabulary in a
/// fraction of a second, and the whole model loaded onto the compute units, which can take
/// minutes. One port for both because both read the one model, so a vocabulary is never checked
/// against a tokenizer the engine does not have. [LAW:one-source-of-truth]
public protocol ModelSupply: Sendable {
    /// The model's tokenizer, read with no Core ML load.
    func prompts() async throws(PromptsUnavailable) -> PromptEncoder
    /// The model resident, hearing for dictation and for the server, its waits taking `turns`.
    /// `phase` is told each step of the load as it begins.
    func load(turns: EngineTurns, phase: @escaping @Sendable (WhisperKitTranscriber.LoadPhase) -> Void) async throws -> LoadedEngine
}

/// A model resident on the compute units: the one engine, as dictation hears through it and as
/// the server's callers do.
public struct LoadedEngine: Sendable {
    public let model: ModelName
    public let dictation: any Transcriber
    public let served: any Transcriber

    public init(model: ModelName, dictation: any Transcriber, served: any Transcriber) {
        self.model = model
        self.dictation = dictation
        self.served = served
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
    /// The model, or why the store does not hold it whole, in the words of the error that said so.
    private let installed: Result<InstalledModel, Unavailable>

    private struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// `store` is the bundle's, read once by the caller, which hands the same store to anything
    /// else that reads the carried model.
    public init(store: ModelStore?) {
        installed = Result {
            guard let store else { throw BundleCarriesNoModel() }
            return try store.installedModel(.default)
        }.mapError { Unavailable(description: "\($0)") }
    }

    public func prompts() async throws(PromptsUnavailable) -> PromptEncoder {
        let installed: InstalledModel
        do { installed = try self.installed.get() } catch { throw PromptsUnavailable(why: "\(error)") }
        return try await PromptEncoder.load(installed)
    }

    public func load(turns: EngineTurns, phase: @escaping @Sendable (WhisperKitTranscriber.LoadPhase) -> Void) async throws -> LoadedEngine {
        let installed = try installed.get()
        phase(.loading)
        let transcriber = try await WhisperKitTranscriber(installed, turns: turns)
        return LoadedEngine(model: transcriber.model, dictation: transcriber, served: transcriber.served)
    }
}

/// A bundle built without the model it is supposed to carry.
///
/// [LAW:no-silent-failure] Not a state this app recovers from and not one it downloads its way
/// out of: the model is put in at build time, so a bundle without one was built wrong and the only
/// thing to do about it is say so where the person running it will read it.
public struct BundleCarriesNoModel: Error, CustomStringConvertible {
    public init() {}

    public var description: String {
        "this build carries no model in Contents/Resources/\(ModelStore.carriedResourceName); "
            + "it was built without one. Build it with `make app`, which puts the model in"
    }
}
