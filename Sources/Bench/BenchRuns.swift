import Foundation
import LowTalkerCore
import os

/// How a bench run ended.
public enum BenchEnding: Hashable, Sendable {
    case finished
    case stopped(BenchStop)
    case failed(String)
}

/// Why a run was stopped before it finished.
public enum BenchStop: Hashable, Sendable {
    /// The person cancelled it.
    case cancelled
    /// A dictation press began, and a press comes before a run.
    case forPress
}

/// The app's one bench run at a time: starting it, cancelling it, telling the log what it
/// does, and keeping served requests off the process's engine while it runs, so a run is not
/// measured against one.
///
/// [LAW:single-enforcer] The window and `LowTalker --bench` both start their run here, so
/// every run is logged by this one owner, an event per row. Whose decode runs is `turns`'
/// rule: a run holds them as a press does, so a served request waits it out, and starts only
/// while no press holds them. A run decodes on engines it loads for itself, so it never keeps a
/// press from dictation's engine: its hold gives way to dictation, and the first press heard
/// during the run stops it at its next hold, once any model load it has begun is done. A run a
/// press was heard during ends saying so, whatever its work did. [LAW:nothing-unseen]
@MainActor
public final class BenchRuns {
    private var current: Task<Void, Never>?
    /// Rows the current run has emitted, for the line that says how it ended.
    private var rows = 0
    /// Whether the person cancelled the current run.
    private var cancelled = false
    /// How many runs have started, so a press's yield reaching the main actor after its run
    /// ended stops no later one.
    private var started = 0
    private let turns: EngineTurns
    private let log: @Sendable (String) -> Void

    /// `turns` are the ones the process's presses and server decode through; `log` is where
    /// each event's line goes, the unified log unless a test listens.
    public init(turns: EngineTurns, log: @escaping @Sendable (String) -> Void = BenchRuns.unifiedLog) {
        self.turns = turns
        self.log = log
    }

    public var isRunning: Bool { current != nil }

    /// Runs `work`, logging and forwarding each event it emits and how it ended. Refused while
    /// another run is going or a press holds the engine. The returned task ends once `ended`
    /// has been told.
    @discardableResult
    public func start(
        _ summary: String,
        work: @escaping @Sendable (_ emit: @escaping @Sendable (BenchEvent) async -> Void) async throws -> Void,
        events: @escaping @MainActor (BenchEvent) -> Void,
        ended: @escaping @MainActor (BenchEnding) -> Void
    ) throws(RunRefused) -> Task<Void, Never> {
        guard !isRunning else { throw .benchmarkRunning }
        guard turns.reading.holds == 0 else { throw .dictationHeld }
        started += 1
        let run = started
        let hold = turns.hold(yieldingToDictation: { Task { @MainActor [weak self] in self?.stop(run: run) } })
        log("bench: started \(summary)")
        rows = 0
        cancelled = false
        let task = Task { [log] in
            let outcome: BenchEnding
            do {
                try await work { event in
                    await MainActor.run {
                        switch event {
                        case .loading(let model): log("bench: loading \(model)")
                        case .row(let row):
                            self.rows += 1
                            log("bench row: \(row.fields)")
                        }
                        events(event)
                    }
                }
                outcome = .finished
            } catch {
                outcome = .failed("\(error)")
            }
            let displaced = hold.release()
            // Why the run was stopped is what is said, ahead of what its work did: a load or a
            // decode cancelled midway throws its own error, not CancellationError, and work
            // told to stop during its last hold finishes anyway, its rows measured beside the
            // press. The release, not the stop, says a press was heard, so a yield still on its
            // way here is not missed.
            let ending: BenchEnding = displaced.yielded ? .stopped(.forPress) : cancelled ? .stopped(.cancelled) : outcome
            log("bench: \(Self.describe(ending, rows: rows)); \(displaced)")
            current = nil
            ended(ending)
        }
        current = task
        return task
    }

    /// Stops the run at its next hold, as the person asked.
    public func cancel() {
        cancelled = true
        stop(run: started)
    }

    /// Stops run number `run` at its next hold, if it is still going.
    private func stop(run: Int) {
        guard run == started else { return }
        current?.cancel()
    }

    /// How a run ended, in the words its last log line and the window say it.
    public static func describe(_ ending: BenchEnding, rows: Int) -> String {
        switch ending {
        case .finished: "finished, \(rows) rows"
        case .stopped(.cancelled): "cancelled after \(rows) rows"
        case .stopped(.forPress): "stopped for a dictation after \(rows) rows"
        case .failed(let reason): "failed after \(rows) rows: \(reason)"
        }
    }

    /// The `bench` category of the app's subsystem, every line public: rows are fixture
    /// speech and numbers, never anything a person dictated.
    public static let unifiedLog: @Sendable (String) -> Void = {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "bench")
        return { logger.notice("\($0, privacy: .public)") }
    }()
}

/// Why a run was not started.
public enum RunRefused: Error, Equatable, CustomStringConvertible {
    case benchmarkRunning
    /// A press holds the engine until its transcript is out.
    case dictationHeld

    public var description: String {
        switch self {
        case .benchmarkRunning: "a benchmark is already running"
        case .dictationHeld: "a dictation is being heard; run once its text is placed"
        }
    }
}
