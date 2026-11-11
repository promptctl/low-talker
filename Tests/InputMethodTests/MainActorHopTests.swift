import Foundation
@testable import InputMethod
import os
import TestProbes
import Testing

/// An IMK callback reaches the main actor however IMK called it, and says which way it came in
/// this process's own log. Each test names its callback with a name no other test uses, so the
/// line it reads back is its own. The store can hand one entry back twice (low-unfiled-50ff.88w),
/// so how often the body ran is counted where it runs, not in lines read back.
@Suite struct MainActorHopTests {
    /// Called on the main thread, as IMK calls, the body runs right there: no queue is waited
    /// on, so a callback can never wait out its own thread.
    @MainActor
    @Test func aCallbackOnTheMainThreadRunsInline() async throws {
        let since = Date.now
        var ran: Int?
        onMainActor("MainActorHopTests.inline", 7) { ran = $0 }
        #expect(ran == 7)
        #expect(try await Self.lines(since: since).contains("MainActorHopTests.inline reached the main actor \(Hop.inline)"))
    }

    /// Called from another thread, the body still runs once, on the main thread, with the
    /// argument it was handed, before the call returns.
    @Test(.timeLimit(.minutes(1))) func aCallbackFromAnotherThreadRunsOnTheMainThreadBeforeReturning() async throws {
        let since = Date.now
        let runs = OSAllocatedUnfairLock<[(onMain: Bool, argument: Int)]>(initialState: [])
        await withCheckedContinuation { done in
            Thread.detachNewThread {
                onMainActor("MainActorHopTests.offThread", 7) { argument in
                    runs.withLock { $0.append((Thread.isMainThread, argument)) }
                }
                done.resume()
            }
        }
        #expect(runs.withLock { $0.map(\.onMain) } == [true])
        #expect(runs.withLock { $0.map(\.argument) } == [7])
        #expect(try await Self.lines(since: since).contains { $0.hasPrefix("MainActorHopTests.offThread reached the main actor from another thread, after waiting ") })
    }

    private static func lines(since: Date) async throws -> [String] {
        try await loggedLines(category: "imk", since: since)
    }
}
