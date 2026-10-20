import Foundation
@testable import InputMethod
import os
import Testing

/// An IMK callback reaches the main actor however IMK called it, and says which way it came.
@Suite struct MainActorHopTests {
    /// Called on the main thread, as IMK calls, the body runs right there: no queue is waited
    /// on, so a callback can never wait out its own thread.
    @MainActor
    @Test func aCallbackOnTheMainThreadRunsInline() {
        var ran: Int?
        let hop = onMainActor("test", 7) { ran = $0 }
        #expect(ran == 7)
        #expect(hop == .inline)
    }

    /// Called from another thread, the body still runs on the main thread, with the argument
    /// it was handed, before the call returns.
    @Test(.timeLimit(.minutes(1))) func aCallbackFromAnotherThreadRunsOnTheMainThreadBeforeReturning() async {
        let seen = OSAllocatedUnfairLock<(onMain: Bool, argument: Int)?>(initialState: nil)
        let hop = await withCheckedContinuation { done in
            Thread.detachNewThread {
                done.resume(returning: onMainActor("test", 7) { argument in
                    seen.withLock { $0 = (Thread.isMainThread, argument) }
                })
            }
        }
        #expect(seen.withLock { $0?.onMain } == true)
        #expect(seen.withLock { $0?.argument } == 7)
        guard case .waited = hop else {
            Issue.record("a call from another thread said it ran \(hop)")
            return
        }
    }
}
