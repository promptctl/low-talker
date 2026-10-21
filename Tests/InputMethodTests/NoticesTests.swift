@testable import InputMethod
import Insertion
import Testing

private let over = Notices.memoryCeiling + 1

/// IMK rule 7: an activation over the memory ceiling tells the app why, then ends the process;
/// one at or under it does neither.
@Suite struct NoticesTests {
    @Test func anActivationOverTheCeilingIsTheLastNotice() async throws {
        let notices = Notices()
        notices.cursorArrived(in: "com.apple.TextEdit")
        notices.activated(holding: over)
        // Finished by the overrun, so nothing told after it is kept and the stream ends.
        notices.cursorArrived(in: "com.apple.TextEdit")
        var heard: [Notices.Notice] = []
        for await notice in notices.notices { heard.append(notice) }
        let overrun = try #require(Overrun(footprint: over, ceiling: Notices.memoryCeiling))
        #expect(heard == [.cursorArrived, .overMemoryCeiling(overrun)])
    }

    @Test(arguments: [Notices.memoryCeiling, 1])
    func anActivationAtOrUnderTheCeilingTellsNothing(footprint: UInt64) async {
        let notices = Notices()
        notices.activated(holding: footprint)
        notices.cursorArrived(in: "com.apple.TextEdit")
        #expect(await notices.notices.first { _ in true } == .cursorArrived)
    }

    /// The overrun is told, and only then does the process end.
    @Test func anOverrunIsToldThenTheProcessEnds() async throws {
        let notices = Notices()
        notices.cursorArrived(in: "com.apple.TextEdit")
        notices.activated(holding: over)
        var did: [String] = []
        await Notices.relay(notices.notices, tell: { notice in did.append("told \(notice)"); return .told }, end: { did.append("ended") })
        let overrun = try #require(Overrun(footprint: over, ceiling: Notices.memoryCeiling))
        #expect(did == ["told cursorArrived", "told \(Notices.Notice.overMemoryCeiling(overrun))", "ended"])
    }

    /// An app that is not running hears nothing, and the process ends all the same.
    @Test func anOverrunNobodyHearsStillEnds() async {
        let notices = Notices()
        notices.activated(holding: over)
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

    @Test func thisProcessFootprintCanBeRead() {
        #expect((ownFootprint() ?? 0) > 0)
    }
}
