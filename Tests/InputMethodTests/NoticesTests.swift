import Foundation
@testable import InputMethod
import Insertion
import os
import Testing

private let over = Notices.memoryCeiling + 1

/// The records one `Notices` produced, in order.
private final class Recorded: Sendable {
    private let records = OSAllocatedUnfairLock<[Notices.Record]>(initialState: [])
    var all: [Notices.Record] { records.withLock { $0 } }

    func notices() -> Notices {
        Notices { record in self.records.withLock { $0.append(record) } }
    }
}

/// IMK rule 7: an activation over the memory ceiling tells the app why, then ends the process;
/// one at or under it does neither.
@Suite struct NoticesTests {
    @Test func anActivationOverTheCeilingIsTheLastNotice() async throws {
        let notices = Recorded().notices()
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
        let notices = Recorded().notices()
        #expect(notices.activated(holding: footprint) == nil)
        notices.cursorArrived(in: "com.apple.TextEdit")
        #expect(await notices.notices.first { _ in true } == .cursorArrived)
    }

    /// The overrun is told, and only then does the process end.
    @Test func anOverrunIsToldThenTheProcessEnds() async throws {
        let notices = Recorded().notices()
        notices.cursorArrived(in: "com.apple.TextEdit")
        let overrun = try #require(notices.activated(holding: over))
        var did: [String] = []
        await notices.relay(tell: { notice in did.append("told \(notice)"); return .told }, end: { did.append("ended") })
        #expect(did == ["told cursorArrived", "told \(Notices.Notice.overMemoryCeiling(overrun))", "ended"])
    }

    /// An app that is not running hears nothing, and the process ends all the same.
    @Test func anOverrunNobodyHearsStillEnds() async {
        let notices = Recorded().notices()
        _ = notices.activated(holding: over)
        var ended = false
        await notices.relay(tell: { _ in .nobodyIsListening(port: "nowhere") }, end: { ended = true })
        #expect(ended)
    }

    /// Arrivals are told for as long as the relay runs, and never end the process: the relay is
    /// stopped here by cancelling it once both are told.
    @Test(.timeLimit(.minutes(1))) func cursorArrivalsAloneNeverEndTheProcess() async {
        let notices = Recorded().notices()
        notices.cursorArrived(in: "com.apple.TextEdit")
        notices.cursorArrived(in: "com.apple.TextEdit")
        let (toldTwice, bothTold) = AsyncStream<Void>.makeStream()
        let ended = OSAllocatedUnfairLock(initialState: false)
        let relaying = Task {
            var told = 0
            await notices.relay(tell: { _ in
                told += 1
                if told == 2 { bothTold.finish() }
                return .told
            }, end: { ended.withLock { $0 = true } })
        }
        for await _ in toldTwice {}
        relaying.cancel()
        await relaying.value
        #expect(!ended.withLock { $0 })
    }

    /// Every activation's footprint is recorded, and an overrun twice: when it is read, and with
    /// how telling the app fared. How telling fared is recorded when it changes.
    @Test func theFootprintTheOverrunAndHowTellingFaredAreRecorded() async throws {
        let recorded = Recorded()
        let notices = recorded.notices()
        notices.cursorArrived(in: "com.apple.TextEdit")
        notices.cursorArrived(in: "com.apple.TextEdit")
        #expect(notices.activated(holding: 4_271) == nil)
        let overrun = try #require(notices.activated(holding: over))
        let nobody = NoticeSender.Told.nobodyIsListening(port: "NoticesTests")
        await notices.relay(tell: { _ in nobody }, end: {})
        #expect(recorded.all == [
            .cursorArrived(in: "com.apple.TextEdit"),
            .cursorArrived(in: "com.apple.TextEdit"),
            .footprint(4_271),
            .footprint(over),
            .overrun(overrun),
            .told(nobody),
            .overrunTold(overrun, nobody),
        ])
    }

    /// What the unified log receives for each record: an overrun is a fault, and a telling that
    /// failed is an error while nobody listening is ordinary.
    @Test func eachRecordIsSaidAtItsLevel() throws {
        let overrun = try #require(Overrun(footprint: over, ceiling: Notices.memoryCeiling))
        #expect(Notices.Record.footprint(4_271).rendering == (.info, "activated holding 4271 bytes of a \(Notices.memoryCeiling) byte ceiling"))
        #expect(Notices.Record.overrun(overrun).rendering == (.fault, "ending this process: \(overrun)"))
        #expect(Notices.Record.overrunTold(overrun, .told).rendering == (.fault, "\(overrun); \(NoticeSender.Told.told)"))
        #expect(Notices.Record.told(.nobodyIsListening(port: "p")).rendering.level == .default)
        #expect(Notices.Record.told(.notTaken(port: "p")).rendering.level == .error)
        #expect(Notices.Record.cursorArrived(in: "com.apple.TextEdit").rendering == (.info, "a cursor arrived in com.apple.TextEdit"))
    }

    @Test func thisProcessFootprintCanBeRead() {
        #expect((ownFootprint() ?? 0) > 0)
    }
}
