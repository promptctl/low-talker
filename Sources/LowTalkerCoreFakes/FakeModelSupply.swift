import LowTalkerCore
import Synchronization
import TestProbes

/// The carried model as a test supplies it: a tokenizer that counts words, or one that did not
/// load, and an engine whose every load waits at a gate the test opens and fails when the test
/// says. `ModelSupplyContract` holds it to the one thing a load promises.
/// [LAW:one-type-per-behavior]
public final class FakeModelSupply: ModelSupply, Sendable {
    private struct State {
        var failures: [String]
        var loads = 0
    }

    private let prompting: Result<PromptEncoder, PromptsUnavailable>
    private let hearing: @Sendable (EngineTurns) -> FakeTranscriber
    private let state: Mutex<State>
    /// Every load waits here until the test opens it; open from the start unless the test holds it.
    public let loading = Gate()
    private let changes: Changes?

    /// `failing` is the reason each load in turn fails with, until they run out and loads land.
    /// `hearing` makes the engine a load lands, on the turns it was loaded with.
    public init(
        prompting: Result<PromptEncoder, PromptsUnavailable> = .success(ConfigSourceContract.prompting),
        failing: [String] = [],
        holding: Bool = false,
        noting changes: Changes? = nil,
        hearing: @escaping @Sendable (EngineTurns) -> FakeTranscriber
    ) {
        self.prompting = prompting
        self.hearing = hearing
        self.changes = changes
        state = Mutex(State(failures: failing))
        if !holding { loading.open() }
    }

    /// How many loads have begun.
    public var loads: Int { state.withLock { $0.loads } }

    public func prompts() async throws(PromptsUnavailable) -> PromptEncoder {
        try prompting.get()
    }

    public func load(turns: EngineTurns, phase: @escaping @Sendable (WhisperKitTranscriber.LoadPhase) -> Void) async throws -> LoadedEngine {
        state.withLock { $0.loads += 1 }
        changes?.note()
        phase(.loading)
        await loading.wait()
        if let failure = state.withLock({ $0.failures.isEmpty ? nil : $0.failures.removeFirst() }) {
            throw LoadFailed(description: failure)
        }
        let engine = hearing(turns)
        return LoadedEngine(model: .default, dictation: engine, served: engine.served)
    }

    public struct LoadFailed: Error, CustomStringConvertible {
        public let description: String
    }
}

/// A model supply's semantics, stated once. `FakeModelSupply` runs it. `CarriedModel` cannot run
/// inside the suite: the suite carries no model. [LAW:one-source-of-truth]
public struct ModelSupplyContract: Sendable {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// A load says it is loading before it lands.
        case aLoadSaysItIsLoadingFirst

        public var description: String {
            switch self {
            case .aLoadSaysItIsLoadingFirst: "a load says it is loading first"
            }
        }
    }

    public let subject: @Sendable () -> any ModelSupply

    public init(subject: @escaping @Sendable () -> any ModelSupply) {
        self.subject = subject
    }

    public func disagreements(with statement: Statement) async throws -> [String] {
        let phases = Mutex<[WhisperKitTranscriber.LoadPhase]>([])
        _ = try await subject().load(turns: EngineTurns()) { phase in phases.withLock { $0.append(phase) } }
        switch statement {
        case .aLoadSaysItIsLoadingFirst:
            let told = phases.withLock { $0 }
            return told.first == .loading ? [] : ["a load that landed told \(told)"]
        }
    }
}
