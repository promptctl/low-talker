import Foundation
@testable import InputMethod
import Testing

/// An IMK callback reaches the main actor however IMK called it, and its record says which way it
/// came. Driven through a controller's `inputText`, the callback that decides least, and read from
/// that controller's records.
@Suite @MainActor struct MainActorHopTests {
    /// Called on the main thread, as IMK calls, the body runs right there: no queue is waited
    /// on, so a callback can never wait out its own thread.
    @Test(.timeLimit(.minutes(1))) func aCallbackOnTheMainThreadRunsInline() async throws {
        let said = try await events(of: { DictationInputController() }) { controller in
            #expect(controller.inputText("a", client: nil) == false)
        }
        try #require(said.count == 3)
        #expect(said[1] == .callback(.inline, .declinedText(holding: "holding no client")))
    }

    /// Called from another thread, the body still runs on the main thread, with the argument it was
    /// handed, before the call returns with the body's answer, and the record says the calling
    /// thread waited for it.
    @Test(.timeLimit(.minutes(1))) func aCallbackFromAnotherThreadRunsOnTheMainThreadBeforeReturning() async throws {
        let said = try await events(of: { DictationInputController() }) { controller in
            nonisolated(unsafe) let controller = controller
            let answer = await withCheckedContinuation { done in
                Thread.detachNewThread { done.resume(returning: controller.didCommand(by: NSSelectorFromString("moveLeft:"), holding: [])) }
            }
            #expect(answer == false)
        }
        try #require(said.count == 3)
        guard case .callback(.waited, .command("moveLeft:", steered: nil, holding: _)) = said[1] else {
            Issue.record("not the command handed, on a callback that waited: \(said[1])")
            return
        }
    }
}
