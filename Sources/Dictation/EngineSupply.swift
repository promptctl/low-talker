import LowTalkerCore

/// The engine as each press finds it at key-down. A load on its way is waited for, so a press
/// made while the model loads is heard once it lands. A load that failed refuses the press
/// before its microphone opens and starts the load again: the load writes a Neural Engine
/// cache outside the model's sealed store, so a failure need not repeat, and one that does not
/// costs one refused press rather than a relaunch.
///
/// [LAW:one-source-of-truth] The current attempt is the one place a press learns whether the
/// model loaded; nothing else keeps a copy of that verdict for presses to read.
@MainActor
public final class EngineSupply {
    /// One attempt at the load: its task, and its failure once the task has failed.
    private struct Attempt {
        let task: Task<any Transcriber, any Error>
        let verdict: Verdict
    }

    @MainActor private final class Verdict {
        var failure: (any Error)?
    }

    private let load: @Sendable () async throws -> any Transcriber
    private var current: Attempt

    /// Starts `load` at once; each press after a failed attempt starts it again.
    public init(load: @escaping @Sendable () async throws -> any Transcriber) {
        self.load = load
        current = Self.attempt(load)
    }

    private static func attempt(_ load: @escaping @Sendable () async throws -> any Transcriber) -> Attempt {
        let verdict = Verdict()
        let task = Task { @MainActor in
            do { return try await load() } catch {
                verdict.failure = error
                throw error
            }
        }
        return Attempt(task: task, verdict: verdict)
    }

    /// What `Dictation` asks at a key-down: the wait for the engine, or the refusal of a press
    /// made after the load failed, which starts the next attempt.
    public func forPress() throws(EngineUnavailable) -> Dictation.Engine {
        if let failure = current.verdict.failure {
            current = Self.attempt(load)
            throw EngineUnavailable(ModelNotLoaded(cause: failure))
        }
        let task = current.task
        return { () async throws(EngineUnavailable) in
            do { return try await task.value } catch { throw EngineUnavailable(error) }
        }
    }
}

/// A press made after the model failed to load, refused at its key-down with the load's reason.
public struct ModelNotLoaded: Error, CustomStringConvertible {
    public let cause: any Error

    public var description: String {
        "the model failed to load (\(cause)), so nothing could hear it; it is loading again, and a press made once it is ready is heard"
    }
}
