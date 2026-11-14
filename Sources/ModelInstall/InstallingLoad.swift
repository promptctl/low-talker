import LowTalkerCore

extension LoadedEngine {
    /// The whole road from a store to a resident model: the store installs whatever
    /// it lacks from `source`, then the model is loaded. `phase` hears each step begin so
    /// a terminal can say what the wait is for.
    ///
    /// [LAW:composability] An install and then the core's own load of what it certified;
    /// the app, which never installs, takes the second half alone as `init(loading:turns:)`.
    public static func load(
        _ model: Model,
        in store: ModelStore,
        from source: ModelSource,
        turns: EngineTurns,
        phase: @escaping @Sendable (InstallingLoadPhase) -> Void
    ) async throws -> LoadedEngine {
        let installed = try await store.install(model, from: source) { phase(.installing($0)) }
        phase(.loading)
        return try await LoadedEngine(loading: installed, turns: turns)
    }

    /// What `load(_:in:from:turns:phase:)` is doing now: the install's phases, then the load's
    /// one. There is no "ready" case: the returned engine is that state.
    public enum InstallingLoadPhase: Equatable, Sendable, CustomStringConvertible {
        case installing(ModelStore.InstallPhase)
        case loading

        public var description: String {
            switch self {
            case .installing(let phase): phase.description
            // [LAW:one-source-of-truth] The load's words are `LoadPhase`'s, which the app's
            // menu shows; the road through an install repeats none of them.
            case .loading: LoadPhase.loading.description
            }
        }
    }
}
