import Foundation
import Testing
@testable import InputSource

/// The supervisor against processes a test ends, so what it tells and when it opens again
/// is read without launching anything.
@MainActor
@Suite struct InputMethodSupervisorTests {
    /// Processes handed out in order, each ended when the test says, and every open counted
    /// with when it came.
    @MainActor final class Launches {
        private(set) var opens: [ContinuousClock.Instant] = []
        private var endings: [Int32: AsyncStream<Never>.Continuation] = [:]
        /// What each open answers in turn: a pid for a process, nil for a refusal.
        var answers: [Int32?]

        init(answering answers: [Int32?]) { self.answers = answers }

        func open() throws -> InputMethodProcess {
            opens.append(.now)
            guard let pid = answers.removeFirst() else { throw Refused() }
            let (ending, end) = AsyncStream<Never>.makeStream()
            endings[pid] = end
            return InputMethodProcess(pid: pid, launched: nil) { for await _ in ending {} }
        }

        func end(_ pid: Int32) { endings[pid]?.finish() }
    }

    struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }

    /// Every event told, and a wait for the `count`th.
    @MainActor final class Told {
        private(set) var events: [InputMethodSupervisor.Event] = []
        func tell(_ event: InputMethodSupervisor.Event) { events.append(event) }

        func until(_ count: Int) async throws -> [InputMethodSupervisor.Event] {
            let giveUp = ContinuousClock.now + .seconds(10)
            while events.count < count, ContinuousClock.now < giveUp { try await Task.sleep(for: .milliseconds(5)) }
            return events
        }
    }

    @Test func aProcessThatEndsIsToldAndOpenedAgain() async throws {
        let launches = Launches(answering: [41, 42])
        let told = Told()
        let supervisor = InputMethodSupervisor(throttleInterval: .zero, open: launches.open, told: told.tell)
        defer { supervisor.stop() }
        #expect(try await told.until(1) == [.running(pid: 41, opening: 1)])
        launches.end(41)
        #expect(try await told.until(3) == [
            .running(pid: 41, opening: 1), .ended(pid: 41, launched: nil), .running(pid: 42, opening: 2),
        ])
    }

    @Test func aRefusedOpenIsToldAndTriedAgainNoSoonerThanTheThrottleAllows() async throws {
        let launches = Launches(answering: [nil, 7])
        let told = Told()
        let supervisor = InputMethodSupervisor(throttleInterval: .milliseconds(300), open: launches.open, told: told.tell)
        defer { supervisor.stop() }
        #expect(try await told.until(2) == [.notOpened("refused", opening: 1), .running(pid: 7, opening: 2)])
        // A lower bound only: a slow machine opens later, never sooner.
        #expect(launches.opens[0].duration(to: launches.opens[1]) >= .milliseconds(300))
    }

    @Test func aStoppedWatchTellsNothingMoreAndOpensNothingMore() async throws {
        let launches = Launches(answering: [5, 6])
        let told = Told()
        let supervisor = InputMethodSupervisor(throttleInterval: .zero, open: launches.open, told: told.tell)
        _ = try await told.until(1)
        supervisor.stop()
        launches.end(5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(told.events == [.running(pid: 5, opening: 1)])
        #expect(launches.opens.count == 1)
    }

    @Test func aWatchNobodyHoldsStops() async throws {
        let launches = Launches(answering: [5, 6])
        let told = Told()
        var supervisor: InputMethodSupervisor? = InputMethodSupervisor(throttleInterval: .zero, open: launches.open, told: told.tell)
        _ = try await told.until(1)
        withExtendedLifetime(supervisor) { supervisor = nil }
        launches.end(5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(launches.opens.count == 1)
    }
}
