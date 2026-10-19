import LoopLifecycle
import Testing

/// A step of the loop the test holds open: each run waits until the test releases it with
/// the answer it gives.
@MainActor
private final class Held<Answer: Sendable> {
    /// How many runs have begun, released or not.
    private(set) var begun = 0
    private var waiting: [CheckedContinuation<Answer, Never>] = []
    /// How many runs are waiting to be released.
    var waiters: Int { waiting.count }

    func run() async -> Answer {
        begun += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ answer: Answer) {
        waiting.removeFirst().resume(returning: answer)
    }
}

/// The app as the lifecycle sees it: a capture and an adopt the test holds, requirements the
/// test meets, a hotkey that watches once a loop is adopted, and every event told.
@MainActor
private final class App {
    let capture = Held<Bool>()
    let adopt = Held<Void>()
    var requirementsMet = true
    var watching = false
    /// How many fresh readings the lifecycle took, which is how an owed reading is seen paid.
    private(set) var readings = 0
    private(set) var events: [LoopLifecycle.Event] = []

    /// Weak, because a test may end while the lifecycle's last task finishes behind it.
    lazy var lifecycle = LoopLifecycle(
        startCapture: { [weak self] in await self?.capture.run() ?? false },
        adopt: { [weak self] in
            await self?.adopt.run()
            self?.watching = true
        },
        requirementsMet: { [weak self] in
            guard let self else { return false }
            readings += 1
            return requirementsMet
        },
        watching: { [weak self] in self?.watching ?? false },
        told: { [weak self] in self?.events.append($0) })

    /// The events with the capture's wait set to zero, so a test can compare them whole.
    var untimed: [LoopLifecycle.Event] {
        events.map { if case .capture(let started, _) = $0 { .capture(started: started, waited: .zero) } else { $0 } }
    }
}

/// Lets what is queued on the main actor run until `holds` is true, and fails if it never is.
@MainActor
private func untilItHolds(_ holds: () -> Bool) async throws {
    for _ in 0..<1000 where !holds() { await Task.yield() }
    try #require(holds())
}

/// The loop's come-ups and rebuilds as readings arrive, against an app the test holds at each
/// step. [LAW:behavior-not-structure]
@MainActor
@Suite struct LoopLifecycleTests {
    /// Two readings in one main-actor turn, as the menu opening and setup coming to the front
    /// can deliver: the first claims the come-up in the step that decides it, so the second is
    /// owed rather than starting a second come-up beside it. Paid when the come-up ends, it
    /// finds the loop up.
    @Test func twoReadingsInOneTurnStartOneComeUpAndOneRebuild() async throws {
        let app = App()
        app.lifecycle.settle(requirementsMet: true)
        app.lifecycle.settle(requirementsMet: true)
        try await untilItHolds { app.capture.waiters == 1 }
        app.capture.release(true)
        try await untilItHolds { app.adopt.waiters == 1 }
        app.adopt.release(())
        try await untilItHolds { app.readings == 1 }
        #expect(app.capture.begun == 1)
        #expect(app.adopt.begun == 1)
        #expect(app.untimed == [
            .settled(.comingUp), .settled(.owed),
            .capture(started: true, waited: .zero),
            .settled(.up),
        ])
    }

    /// Readings that arrive while a rebuild runs are owed to its end and paid there once, with
    /// one fresh reading, however many arrived.
    @Test func readingsDuringARebuildArePaidOnceItEnds() async throws {
        let app = App()
        app.watching = true
        app.lifecycle.inputMethodWasSwitchedOn()
        app.lifecycle.settle(requirementsMet: true)
        try await untilItHolds { app.adopt.waiters == 1 }
        app.lifecycle.settle(requirementsMet: true)
        app.lifecycle.settle(requirementsMet: true)
        #expect(app.readings == 0)
        app.adopt.release(())
        try await untilItHolds { app.readings == 1 }
        for _ in 0..<10 { await Task.yield() }
        #expect(app.readings == 1)
        #expect(app.adopt.begun == 1)
        #expect(app.untimed == [.settled(.rebuilding), .settled(.owed), .settled(.owed), .settled(.up)])
    }

    /// A reading owed to a come-up whose capture did not start is acted on when it is paid: the
    /// loop is still down, so it comes up again. A loop that came down is never down until a
    /// relaunch.
    @Test func aReadingOwedToAComeUpThatLeftTheLoopDownBringsItUpAgain() async throws {
        let app = App()
        app.lifecycle.settle(requirementsMet: true)
        try await untilItHolds { app.capture.waiters == 1 }
        app.lifecycle.settle(requirementsMet: true)
        app.capture.release(false)
        try await untilItHolds { app.capture.waiters == 1 }
        #expect(app.capture.begun == 2)
        #expect(app.adopt.begun == 0)
        app.capture.release(true)
        try await untilItHolds { app.adopt.waiters == 1 }
        app.adopt.release(())
        try await untilItHolds { app.watching }
        #expect(app.untimed == [
            .settled(.comingUp), .settled(.owed),
            .capture(started: false, waited: .zero),
            .settled(.comingUp),
            .capture(started: true, waited: .zero),
        ])
    }

    /// A come-up asked for while one is under way joins it: the same task, one capture.
    @Test func aComeUpDuringAComeUpJoinsIt() async throws {
        let app = App()
        let first = app.lifecycle.comeUp()
        let second = app.lifecycle.comeUp()
        #expect(first == second)
        try await untilItHolds { app.capture.waiters == 1 }
        app.capture.release(true)
        try await untilItHolds { app.adopt.waiters == 1 }
        app.adopt.release(())
        await first.value
        #expect(app.capture.begun == 1)
        #expect(app.untimed == [.joined, .capture(started: true, waited: .zero)])
    }

    /// A capture that did not start builds no loop over it.
    @Test func aCaptureThatDidNotStartBuildsNoLoop() async throws {
        let app = App()
        let up = app.lifecycle.comeUp()
        try await untilItHolds { app.capture.waiters == 1 }
        app.capture.release(false)
        await up.value
        #expect(app.adopt.begun == 0)
        #expect(app.untimed == [.capture(started: false, waited: .zero)])
    }

    /// The come-up says how long capture took to start, which is how long a slow input kept
    /// the loop down.
    @Test func theComeUpTellsHowLongCaptureTookToStart() async throws {
        let app = App()
        let up = app.lifecycle.comeUp()
        try await untilItHolds { app.capture.waiters == 1 }
        try await Task.sleep(for: .milliseconds(50))
        app.capture.release(false)
        await up.value
        guard case .capture(false, let waited) = try #require(app.events.first) else {
            Issue.record("the come-up told \(app.events), not its capture's wait")
            return
        }
        #expect(waited >= .milliseconds(50))
    }

    /// A quit while capture is starting lets the come-up end without building a loop: the
    /// rebuild it asks for afterwards is refused, puts no hotkey up, and says so.
    @Test func aQuitDuringTheCaptureWaitBuildsNoLoop() async throws {
        let app = App()
        let up = app.lifecycle.comeUp()
        try await untilItHolds { app.capture.waiters == 1 }
        #expect(app.lifecycle.quit() == nil)
        app.capture.release(true)
        await up.value
        #expect(app.adopt.begun == 0)
        #expect(!app.watching)
        #expect(app.untimed == [.capture(started: true, waited: .zero), .refused(.rebuild)])
    }

    /// After a quit, a come-up starts no capture, which could open the microphone the quit let
    /// go, and a reading is dropped.
    @Test func afterAQuitNothingStarts() async throws {
        let app = App()
        _ = app.lifecycle.quit()
        await app.lifecycle.comeUp().value
        app.lifecycle.settle(requirementsMet: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(app.capture.begun == 0)
        #expect(app.adopt.begun == 0)
        #expect(app.untimed == [.refused(.comeUp), .settled(.quitting)])
    }

    /// A quit hands back the rebuild under way, so it can let that loop finish being built and
    /// take down the last one.
    @Test func aQuitHandsBackTheRebuildUnderWay() async throws {
        let app = App()
        app.watching = true
        app.lifecycle.inputMethodWasSwitchedOn()
        app.lifecycle.settle(requirementsMet: true)
        try await untilItHolds { app.adopt.waiters == 1 }
        let rebuilding = try #require(app.lifecycle.quit())
        app.adopt.release(())
        await rebuilding.value
        #expect(app.adopt.begun == 1)
    }

    /// A come-up that reaches its rebuild while another rebuild runs waits for it: only one loop
    /// is ever being built.
    @Test func aRebuildAskedForDuringAnotherWaitsForIt() async throws {
        let app = App()
        app.watching = true
        app.lifecycle.inputMethodWasSwitchedOn()
        app.lifecycle.settle(requirementsMet: true)
        try await untilItHolds { app.adopt.waiters == 1 }
        let up = app.lifecycle.comeUp()
        try await untilItHolds { app.capture.waiters == 1 }
        app.capture.release(true)
        for _ in 0..<10 { await Task.yield() }
        #expect(app.adopt.begun == 1)
        app.adopt.release(())
        try await untilItHolds { app.adopt.waiters == 1 }
        #expect(app.adopt.begun == 2)
        app.adopt.release(())
        await up.value
    }

    /// A reading that finds a requirement unmet leaves the loop as it stands.
    @Test func aReadingWithARequirementUnmetStartsNothing() async throws {
        let app = App()
        app.lifecycle.settle(requirementsMet: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(app.capture.begun == 0)
        #expect(app.untimed == [.settled(.unmet)])
    }
}
