import Foundation
@testable import LowTalkerCore
import Testing

/// When the watch speaks, rather than what it says.
///
/// [LAW:decomposition] The suites that read configs out of a watch cannot get at this: a
/// reading shows what the filesystem held at the moment it was taken, and never how long
/// the watch waited before taking it. So the delay is asserted here, on the type that
/// owns it.
@Suite struct DirectoryChangesTests {
    /// Nothing is reported before the latency has run.
    ///
    /// This is what leaving `kFSEventStreamCreateFlagNoDefer` off buys, and it is the
    /// regression test for that flag staying off. A save that unlinks the file before
    /// writing the new one is two changes a few milliseconds apart, and holding the first
    /// back until the batch has settled is the only reason it reads as one save rather
    /// than as a deletion followed by a creation.
    ///
    /// The flag is pinned here, at the mechanism, rather than by replaying the save that
    /// exposed it. That save can only be staged as a gap between two statements, and a gap
    /// is a bet: the runner that freezes this process for seconds at a time widens it past
    /// the latency, at which point the file really is missing and reporting the defaults is
    /// the right answer. Early delivery is the fault underneath that symptom, and it can be
    /// asked about directly. [LAW:behavior-not-structure]
    ///
    /// [LAW:no-ambient-temporal-coupling] A floor is the one timing claim a loaded machine
    /// cannot break. A stall, a busy scheduler, a slow disk can each only push the tick
    /// *later*, and what is asserted is that it did not come *sooner* - which is why the
    /// clock is read before the directory and its stream are made, where every hazard that
    /// follows lands inside the measured span instead of shortening it. Read after them, the
    /// span missed the directory's own creation and the stream's start, either of which can
    /// open the window the latency is counted from: a tick 39 ms after the write.
    ///
    /// Half the latency and not all of it, so that a coalescing timer firing a hair early
    /// is not a failure. Measured: the flag put back lands the tick in 5 ms and off again
    /// in 105 ms, so neither margin is near the half.
    @Test(.timeLimit(.minutes(1)))
    func aChangeIsNotReportedBeforeTheLatencyHasRun() async throws {
        let before = ContinuousClock.now
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "low-talker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var ticks = DirectoryChanges.ticks(under: directory).makeAsyncIterator()
        try "a change".write(to: directory.appending(path: "note.txt"), atomically: true, encoding: .utf8)

        try #require(await ticks.next())
        #expect(ContinuousClock.now - before >= .seconds(DirectoryChanges.latency / 2))
    }
}
