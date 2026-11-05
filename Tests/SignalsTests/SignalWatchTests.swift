import Foundation
import LowTalkerCore
import Signals
import TestProbes
import Testing

@Suite struct SignalWatchTests {
    /// `SIGUSR1` ends a process that has not been told otherwise, so a run that reaches
    /// the assertion at all is half the proof. The other half is that each number gets
    /// its own answer: the signal nobody sent is the one whose flag stays down.
    @Test func aWatchedSignalIsAnsweredWithItsOwnNumberRatherThanEndingTheProcess() async throws {
        let user1 = Flag()
        let user2 = Flag()
        let watch = SignalWatch(on: [SIGUSR1, SIGUSR2]) { number in
            (number == SIGUSR1 ? user1 : user2).raise()
        }
        kill(getpid(), SIGUSR1)
        await user1.changed.settled { user1.raised }
        #expect(!user2.raised)
        // The sources stop when the watch goes, and nothing below reads it.
        withExtendedLifetime(watch) {}
    }
}
