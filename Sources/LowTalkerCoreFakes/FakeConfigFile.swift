import LowTalkerCore
import Synchronization

/// The config file held in memory: its text, or no file, read by the one parser the real file is
/// read by, and every save told to the reloads at once rather than when a directory watch fires.
/// `ConfigSourceContract` holds it to `ConfigFileSource`. [LAW:one-type-per-behavior]
public final class FakeConfigFile: ConfigSource, Sendable {
    private struct Watch {
        var last: RunningConfig
        let prompting: Prompting
        let continuation: AsyncStream<RunningConfig>.Continuation
    }

    private struct State {
        var text: String?
        var watches: [Int: Watch] = [:]
        var next = 0
    }

    private let state: Mutex<State>

    /// The file's text, or nil for no file.
    public init(_ text: String? = nil) {
        state = Mutex(State(text: text))
    }

    /// Writes the file, or removes it with nil, and tells every reload what it now reads as.
    public func save(_ text: String?) {
        let told = state.withLock { state -> [(AsyncStream<RunningConfig>.Continuation, RunningConfig)] in
            state.text = text
            return state.watches.keys.sorted().compactMap { id in Self.advance(&state.watches[id]!, reading: text) }
        }
        for (continuation, next) in told { continuation.yield(next) }
    }

    public func read(prompting: Prompting) -> Result<Config, ConfigError> {
        Self.reading(state.withLock { $0.text }, prompting: prompting)
    }

    public func reloads(after running: RunningConfig, prompting: Prompting) -> AsyncStream<RunningConfig> {
        let (stream, continuation) = AsyncStream.makeStream(of: RunningConfig.self)
        let (id, first) = state.withLock { state -> (Int, (AsyncStream<RunningConfig>.Continuation, RunningConfig)?) in
            let id = state.next
            state.next += 1
            var watch = Watch(last: running, prompting: prompting, continuation: continuation)
            // Read once as the watch comes up, as the file's is, so a save between the launch
            // reading and the reloads is not missed.
            let first = Self.advance(&watch, reading: state.text)
            state.watches[id] = watch
            return (id, first)
        }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.watches.removeValue(forKey: id) } }
        if let (continuation, next) = first { continuation.yield(next) }
        return stream
    }

    private static func advance(_ watch: inout Watch, reading text: String?) -> (AsyncStream<RunningConfig>.Continuation, RunningConfig)? {
        guard let next = watch.last.next(reading: reading(text, prompting: watch.prompting)) else { return nil }
        watch.last = next
        return (watch.continuation, next)
    }

    /// What `Config.load` answers for this text: the defaults with no file, and the parse of it
    /// otherwise.
    private static func reading(_ text: String?, prompting: Prompting) -> Result<Config, ConfigError> {
        guard let text else { return .success(.default) }
        return Result { () throws(ConfigError) in try Config(toml: text, prompting: prompting) }
    }
}
