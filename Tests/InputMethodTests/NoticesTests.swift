import Foundation
@testable import InputMethod
import Insertion
import TestProbes
import Testing

private let over = Notices.memoryCeiling + 1

/// IMK rule 7: an activation over the memory ceiling tells the app why, then ends the process;
/// one at or under it does neither.
@Suite struct NoticesTests {
    @Test func anActivationOverTheCeilingIsTheLastNotice() async throws {
        let notices = Notices()
        notices.cursorArrived(in: "com.apple.TextEdit")
        let overrun = try #require(notices.activated(holding: over))
        #expect(overrun == Overrun(footprint: over, ceiling: Notices.memoryCeiling))
        // Finished by the overrun, so nothing told after it is kept and the stream ends.
        notices.cursorArrived(in: "com.apple.TextEdit")
        var heard: [Notices.Notice] = []
        for await notice in notices.notices { heard.append(notice) }
        #expect(heard == [.cursorArrived, .overMemoryCeiling(overrun)])
    }

    @Test(arguments: [Notices.memoryCeiling, 1])
    func anActivationAtOrUnderTheCeilingTellsNothing(footprint: UInt64) async {
        let notices = Notices()
        #expect(notices.activated(holding: footprint) == nil)
        notices.cursorArrived(in: "com.apple.TextEdit")
        #expect(await notices.notices.first { _ in true } == .cursorArrived)
    }

    /// The overrun is told, and only then does the process end.
    @Test func anOverrunIsToldThenTheProcessEnds() async throws {
        let notices = Notices()
        notices.cursorArrived(in: "com.apple.TextEdit")
        let overrun = try #require(notices.activated(holding: over))
        var did: [String] = []
        await Notices.relay(notices.notices, tell: { notice in did.append("told \(notice)"); return .told }, end: { did.append("ended") })
        #expect(did == ["told cursorArrived", "told \(Notices.Notice.overMemoryCeiling(overrun))", "ended"])
    }

    /// An app that is not running hears nothing, and the process ends all the same.
    @Test func anOverrunNobodyHearsStillEnds() async {
        let notices = Notices()
        _ = notices.activated(holding: over)
        var ended = false
        await Notices.relay(notices.notices, tell: { _ in .nobodyIsListening(port: "nowhere") }, end: { ended = true })
        #expect(ended)
    }

    @Test func cursorArrivalsAloneNeverEndTheProcess() async {
        let (arrivals, continuation) = AsyncStream<Notices.Notice>.makeStream()
        continuation.yield(.cursorArrived)
        continuation.yield(.cursorArrived)
        continuation.finish()
        var told = 0
        var ended = false
        await Notices.relay(arrivals, tell: { _ in told += 1; return .told }, end: { ended = true })
        #expect(told == 2)
        #expect(!ended)
    }

    /// Every activation's footprint is in the log, and an overrun is a fault there twice: when
    /// it is read, and with how telling the app fared. Values no other test uses, so the lines
    /// read back are this test's own.
    @Test func theFootprintAndAnOverrunAreSaidInTheLog() async throws {
        let since = Date.now
        let notices = Notices()
        #expect(notices.activated(holding: 4_271) == nil)
        let overrun = try #require(notices.activated(holding: 5_123_456_789))
        await Notices.relay(notices.notices, tell: { _ in .nobodyIsListening(port: "NoticesTests.log") }, end: {})
        let lines = try await loggedLines(category: "notices", since: since)
        #expect(lines.contains("activated holding 4271 bytes of a \(Notices.memoryCeiling) byte ceiling"))
        #expect(lines.contains("activated holding 5123456789 bytes of a \(Notices.memoryCeiling) byte ceiling"))
        #expect(lines.contains("ending this process: \(overrun)"))
        #expect(lines.contains("\(overrun); \(NoticeSender.Told.nobodyIsListening(port: "NoticesTests.log"))"))
    }

    @Test func thisProcessFootprintCanBeRead() {
        #expect((ownFootprint() ?? 0) > 0)
    }
}
