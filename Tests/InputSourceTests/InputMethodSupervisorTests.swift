import Foundation
import Synchronization
import Testing
import TestProbes
import Uptime
@testable import InputSource

/// The supervisor against processes a test ends, so what it tells and when it opens again
/// is read without launching anything.
@MainActor
@Suite struct InputMethodSupervisorTests {
    /// Processes handed out in order, each ended when the test says, and every open counted
    /// with the clock instant it came at.
    @MainActor final class Launches {
        private(set) var opens: [HostTime] = []
        private var endings: [Int32: AsyncStream<Never>.Continuation] = [:]
        /// What each open answers in turn: a pid for a process, nil for a refusal.
        var answers: [Int32?]
        /// The clock each open is stamped on - the supervisor's own, so gaps between opens are
        /// read on the time the test advances, not on the wall.
        let clock: HostClock

        init(answering answers: [Int32?], clock: HostClock = .system) {
            self.answers = answers
            self.clock = clock
        }

        func open() throws -> RunningInputMethod {
            opens.append(clock.now)
            guard let pid = answers.removeFirst() else { throw Refused() }
            let (ending, end) = AsyncStream<Never>.makeStream()
            endings[pid] = end
            return RunningInputMethod(pid: pid, launched: nil) { for await _ in ending {} }
        }

        func end(_ pid: Int32) { endings[pid]?.finish() }
    }

    struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }

    /// Every event told, and a wait for the `count`th that wakes when it is told, not when a
    /// clock runs out. [LAW:no-ambient-temporal-coupling]
    @MainActor final class Told {
        private(set) var events: [InputMethodSupervisor.Event] = []
        let changed = Changes()
        func tell(_ event: InputMethodSupervisor.Event) { events.append(event); changed.note() }

        /// Await the `count`th event. A count that never arrives hangs for the runner's outer
        /// timeout to name, rather than reading on past events never told. [LAW:no-silent-failure]
        func until(_ count: Int) async -> [InputMethodSupervisor.Event] {
            await changed.settled { events.count >= count }
            return events
        }
    }

    @Test func aProcessThatEndsIsToldAndOpenedAgain() async {
        let launches = Launches(answering: [41, 42])
        let told = Told()
        let supervisor = InputMethodSupervisor(throttleInterval: .zero, open: launches.open, told: told.tell)
        defer { supervisor.stop() }
        #expect(await told.until(1) == [.running(pid: 41, opening: 1)])
        launches.end(41)
        #expect(await told.until(3) == [
            .running(pid: 41, opening: 1), .ended(pid: 41, launched: nil), .running(pid: 42, opening: 2),
        ])
    }

    @Test func aRefusedOpenIsToldAndTriedAgainNoSoonerThanTheThrottleAllows() async {
        let clock = ManualHostClock()
        let launches = Launches(answering: [nil, 7], clock: clock.clock)
        let told = Told()
        let supervisor = InputMethodSupervisor(throttleInterval: .milliseconds(300), clock: clock.clock, open: launches.open, told: told.tell)
        defer { supervisor.stop() }
        // The first open is refused and told; the watch is now parked in the throttle.
        #expect(await told.until(1) == [.notOpened("refused", opening: 1)])
        // Not a tick before the throttle: advancing short of it wakes no sleeper, so the second
        // open is unreachable - the lower bound proven, not raced. [LAW:behavior-not-structure]
        clock.advance(by: .milliseconds(299))
        #expect(launches.opens.count == 1)
        // At the throttle the watch opens again.
        clock.advance(by: .milliseconds(1))
        #expect(await told.until(2) == [.notOpened("refused", opening: 1), .running(pid: 7, opening: 2)])
        #expect(launches.opens[0].duration(to: launches.opens[1]) == .milliseconds(300))
    }

    @Test func aStoppedWatchTellsNothingMoreAndOpensNothingMore() async {
        let launches = Launches(answering: [5, 6])
        let told = Told()
        let supervisor = InputMethodSupervisor(throttleInterval: .zero, open: launches.open, told: told.tell)
        _ = await told.until(1)
        supervisor.stop()
        launches.end(5)
        // Await the watch finishing, not a wall-clock guess: once it has wound down, what it
        // told and opened is final. [LAW:no-ambient-temporal-coupling]
        await supervisor.watching?.value
        #expect(told.events == [.running(pid: 5, opening: 1)])
        #expect(launches.opens.count == 1)
    }

    @Test func aWatchNobodyHoldsStops() async {
        let launches = Launches(answering: [5, 6])
        let told = Told()
        var supervisor: InputMethodSupervisor? = InputMethodSupervisor(throttleInterval: .zero, open: launches.open, told: told.tell)
        _ = await told.until(1)
        // The watch holds `self` weakly, so this reference does not keep the supervisor alive:
        // dropping the strong one below deinits it, which cancels the watch.
        let watch = supervisor!.watching
        withExtendedLifetime(supervisor) { supervisor = nil }
        launches.end(5)
        await watch?.value
        #expect(launches.opens.count == 1)
    }
}
