import Dictation
import LowTalkerCore
import Synchronization
import Testing
import TestProbes

/// The engine as a press finds it at key-down: waited for while it loads, refused once its
/// load has failed, and loaded again by that refusal.
@MainActor
@Suite struct EngineSupplyTests {
    private struct LoadFailed: Error, CustomStringConvertible {
        var description: String { "a weight file is truncated" }
    }

    /// A press made while the load runs waits for it, and gets the engine it lands with.
    @Test func aPressMadeWhileTheModelLoadsWaitsForIt() async throws {
        let loaded = Gate()
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let supply = EngineSupply { _ in
            await loaded.wait()
            return engine
        }
        let waiting = try supply.forPress()
        loaded.open()
        #expect(try await waiting() as? FakeTranscriber === engine)
    }

    /// A press made once the load has failed is refused with the load's reason, and the
    /// refusal starts the next attempt at the load, so the press after it is heard. A press
    /// already waiting on the failed load is told the engine is unavailable.
    @Test func aPressAfterAFailedLoadIsRefusedAndLoadsTheModelAgain() async throws {
        let loads = Mutex<[Int]>([])
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let supply = EngineSupply { attempt in
            loads.withLock { $0.append(attempt) }
            guard attempt > 1 else { throw LoadFailed() }
            return engine
        }
        let waiting = try supply.forPress()
        await #expect(throws: EngineUnavailable.self) { try await waiting() }

        let refusal = try #require(throws: EngineUnavailable.self) { try supply.forPress() }
        #expect((refusal.cause as? ModelNotLoaded)?.cause is LoadFailed)
        #expect(refusal.description == "the model failed to load (a weight file is truncated), so nothing could hear it; this press started load attempt 2")

        #expect(try await supply.forPress()() as? FakeTranscriber === engine)
        #expect(loads.withLock { $0 } == [1, 2])
    }
}
