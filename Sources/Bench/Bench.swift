import Foundation
import LowTalkerCore
import Uptime

/// What a bench run tells its surface while it runs: a model about to load, and each row as
/// its model's report comes in.
public enum BenchEvent: Hashable, Sendable {
    case loading(ModelName)
    case row(BenchRow)
}

/// The latency harness over a fixture folder: every model asked for, held every way asked
/// for, one row per model, fixture, delivery and serving. This is how the default model was
/// chosen and how the streaming and vocabulary work measure themselves.
///
/// [LAW:effects-at-boundaries] The engine arrives through `load` and the rows leave through
/// `emit`, so the menu-bar app, its binary run from a terminal and a test all run this one
/// loop and differ only in what stands at its two ends.
public enum Bench {
    /// Measures `plan` over `fixtures`, one model at a time, each loaded through `load` and
    /// let go of before the next. A cancelled run stops at the next hold.
    public static func measure(
        _ fixtures: [Fixture],
        plan: BenchPlan,
        load: @escaping @Sendable (ModelName) async throws -> LatencyHarness.Engine,
        emit: (BenchEvent) async -> Void
    ) async throws {
        for model in plan.models {
            try Task.checkCancellation()
            await emit(.loading(model))
            let report = try await LatencyHarness.measure(
                fixtures, arrivals: plan.arrivals, servings: plan.servings, reruns: UInt(plan.runs - 1), expecting: plan.vocabulary,
                on: HostClock.system
            ) { try await load(model) }
            for result in report.fixtures {
                await emit(.row(BenchRow(model: model, load: report.load, result: result)))
            }
        }
    }

    /// A run as the app asks for one: the fixtures and a picked store read through their
    /// bookmarks in `folders`, the carried store from `carried`, and each model loaded from
    /// whichever store `options` names. The store's folder stays open for the whole run,
    /// since a model is read as it loads.
    public static func run(
        _ options: BenchOptions,
        folders: BenchFolders,
        carried: ModelStore?,
        load: @escaping @Sendable (ModelStore, ModelName) async throws -> LatencyHarness.Engine,
        emit: (BenchEvent) async -> Void
    ) async throws {
        let fixtures = try folders.open(options.fixtures).reading { try Fixture.load(directory: $0) }
        let opened: OpenFolder?
        let store: ModelStore
        switch options.store {
        case .carried:
            guard let carried else { throw CarriesNoStore() }
            (opened, store) = (nil, carried)
        case .folder(let folder):
            let open = try folders.open(folder)
            (opened, store) = (open, ModelStore(directory: open.url))
        }
        // The folder closes as `opened` goes, so it is held until the last model has loaded.
        defer { withExtendedLifetime(opened) {} }
        try await measure(fixtures, plan: options.plan, load: { try await load(store, $0) }, emit: emit)
    }

    /// A model loaded in place from `store`, never written to, and the engine a bench holds
    /// it through: the app's own way to load, so the app's bench reads what dictation reads.
    @Sendable public static func loadInPlace(_ store: ModelStore, _ model: ModelName) async throws -> LatencyHarness.Engine {
        let turns = EngineTurns()
        let engine = try await WhisperKitTranscriber.loadInPlace(model, in: store, turns: turns) { _ in }
        return LatencyHarness.Engine(dictation: engine, served: engine.served, turns: turns)
    }
}

/// A run asked for the carried store in a process whose bundle carries none.
public struct CarriesNoStore: Error, CustomStringConvertible {
    public init() {}

    public var description: String {
        "this build carries no model store; pick a store folder in the Benchmark window, or pass --models-dir"
    }
}
