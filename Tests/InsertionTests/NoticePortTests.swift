import Darwin
import DarwinCalls
import Foundation
@testable import Insertion
import Testing

/// What the hotkey port did, in the order it did it, for a case to wait on.
private enum Arrival: Equatable {
    case heard(InputMethodNotice)
    case told(String)
}

/// The app's end of the hotkey port on `name`, hearing `senders`, with everything it does
/// arriving on the stream it hands back.
private func hostNotices(name: String, senders: PeerIdentity) throws -> (port: NoticePort, arrivals: AsyncStream<Arrival>) {
    let (arrivals, continuation) = AsyncStream<Arrival>.makeStream()
    let port = try NoticePort(
        portName: name, senders: senders, queue: DispatchQueue(label: name),
        told: { continuation.yield(.told($0.description)) }, heard: { continuation.yield(.heard($0)) })
    return (port, arrivals)
}

/// Cursor arrivals cross from the input method to the app, from the input method alone.
///
/// Both ends run in this process, which the port is told to hear: the check that matters is
/// that a sender it was not told to hear is not heard, and that is a different sender, not a
/// different process. [LAW:behavior-not-structure]
@Suite struct NoticePortTests {
    @Test(.timeLimit(.minutes(1))) func everyCursorArrivalIsHeard() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        let sender = NoticeSender(portName: name, build: aBuild)
        #expect((0..<3).map { _ in sender.tellCursorArrived() } == Array(repeating: .told, count: 3))
        var arrived: [Arrival] = []
        for await arrival in arrivals.prefix(3) { arrived.append(arrival) }
        #expect(arrived == Array(repeating: .heard(.cursorArrived(CursorArrival(pid: getpid(), build: aBuild))), count: 3))
        withExtendedLifetime(port) {}
    }

    /// An input method whose bundle carries no build tells its arrivals without one, as every
    /// input method from before builds were compared does, and the app hears that it said none.
    @Test(.timeLimit(.minutes(1))) func anArrivalWithoutABuildIsHeardSayingNone() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        #expect(NoticeSender(portName: name, build: nil).tellCursorArrived() == .told)
        #expect(await arrivals.first(where: { _ in true }) == .heard(.cursorArrived(CursorArrival(pid: getpid(), build: nil))))
        withExtendedLifetime(port) {}
    }

    /// A cursor arrival carries a build or nothing, so one carrying other bytes is not one.
    @Test func aCursorArrivalCarryingBytesThatAreNoBuildIsNotOne() {
        let arrival = { (build: Build?) in InputMethodNotice.cursorArrived(CursorArrival(pid: 7, build: build)) }
        #expect(Wire.notice(id: Wire.cursorArrived, payload: nil, from: 7) == arrival(nil))
        #expect(Wire.notice(id: Wire.cursorArrived, payload: Data(), from: 7) == arrival(nil))
        #expect(Wire.notice(id: Wire.cursorArrived, payload: Wire.said(aBuild), from: 7) == arrival(aBuild))
        #expect(Wire.notice(id: Wire.cursorArrived, payload: Data([1]), from: 7) == nil)
        #expect(Wire.notice(id: Wire.greeting, payload: Wire.said(aBuild), from: 7) == nil)
    }

    /// The input method ending itself over its memory ceiling is heard with what it held and
    /// the ceiling it held it over, so the app can say both.
    @Test(.timeLimit(.minutes(1))) func anOverrunIsHeardWithWhatItHeld() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        let overrun = try #require(Overrun(footprint: 1_500_000_000, ceiling: 1 << 30))
        #expect(NoticeSender(portName: name, build: aBuild).tellOverMemoryCeiling(overrun) == .told)
        #expect(await arrivals.first(where: { _ in true }) == .heard(.overMemoryCeiling(pid: getpid(), overrun)))
        withExtendedLifetime(port) {}
    }

    /// An overrun is only ever over, and only by what a byte count can say: one at or under its
    /// ceiling, or past that, cannot be made, nor read off the wire from a sender that wrote one.
    @Test func anOverrunAtOrUnderItsCeilingIsNone() throws {
        #expect(Overrun(footprint: 1 << 30, ceiling: 1 << 30) == nil)
        #expect(Overrun(footprint: 1, ceiling: 1 << 30) == nil)
        #expect(Overrun(footprint: UInt64(Int64.max) + 1, ceiling: 1 << 30) == nil)
        let under = Data(#"{"footprint":1,"ceiling":1073741824}"#.utf8)
        #expect(Wire.notice(id: Wire.overMemoryCeiling, payload: under, from: 7) == nil)
        let unsayable = Data(#"{"footprint":18446744073709551615,"ceiling":1073741824}"#.utf8)
        #expect(Wire.notice(id: Wire.overMemoryCeiling, payload: unsayable, from: 7) == nil)
        #expect(Wire.notice(id: Wire.overMemoryCeiling, payload: nil, from: 7) == nil)
        let over = try #require(Overrun(footprint: (1 << 30) + 1, ceiling: 1 << 30))
        #expect(Wire.notice(id: Wire.overMemoryCeiling, payload: Wire.overrun(over), from: 7) == .overMemoryCeiling(pid: 7, over))
    }

    /// Said in the units Activity Monitor uses, so a person can hold it to what they see there.
    @Test func anOverrunSaysWhatItHeldInMemoryUnits() throws {
        let overrun = try #require(Overrun(footprint: 3 << 29, ceiling: 1 << 30))
        #expect(overrun.description == "holding 1.5 GB, over its 1 GB ceiling")
    }

    /// The name is one anyone can compute, and an arrival heard from anyone would offer held
    /// words to whatever has focus: a sender that is not the one named is said by name and
    /// never heard.
    @Test(.timeLimit(.minutes(1))) func aSenderThatIsNotTheInputMethodIsNotHeard() async throws {
        let name = aPortNobodyElseUses()
        let someoneElse = PeerIdentity.signed(identifier: "ai.promptctl.low-talker.test.inputmethod", certificate: String(repeating: "0", count: 40))
        let (port, arrivals) = try hostNotices(name: name, senders: someoneElse)
        #expect(NoticeSender(portName: name, build: aBuild).tellCursorArrived() == .told)
        guard case .told(let said)? = await arrivals.first(where: { _ in true }) else {
            Issue.record("the port heard a sender it was not told to hear")
            return
        }
        #expect(said.contains("ignored a notice told by pid \(getpid())"))
        #expect(said.contains(someoneElse.description))
        withExtendedLifetime(port) {}
    }

    /// The modifier keys an input method from before this app still sends, on the id they
    /// had, are said as not understood, not dropped and not misread.
    @Test(.timeLimit(.minutes(1))) func aMessageThatIsNotACursorArrivalIsSaidSo() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        var remote = mach_port_t()
        try #require(lt_bootstrap_look_up(name, &remote) == KERN_SUCCESS)
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let modifiersFromBefore: mach_msg_id_t = 3
        let sent = Mach.send(
            Data(repeating: 0, count: 16), id: modifiersFromBefore, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: Mach.noPort, timeout: aBudgetTheRunnerCannotSpend)
        try #require(sent == MACH_MSG_SUCCESS)
        #expect(await arrivals.first(where: { _ in true }) == .told(NoticePort.Event.notUnderstood(id: modifiersFromBefore, bytes: 16).description))
        withExtendedLifetime(port) {}
    }

    @Test func anArrivalWithNobodyListeningSaysSo() {
        let name = aPortNobodyElseUses()
        #expect(NoticeSender(portName: name, build: aBuild).tellCursorArrived() == .nobodyIsListening(port: name))
    }

    /// The app hosts the name again each time it rebuilds its loop, straight after letting
    /// the last one go, so a released port has given its name up by the time the release
    /// returns. [LAW:no-ambient-temporal-coupling]
    @Test func aReleasedPortsNameCanBeHostedAgainAtOnce() throws {
        let name = aPortNobodyElseUses()
        for _ in 0..<50 {
            _ = try hostNotices(name: name, senders: try OwnProcess.identity())
        }
    }
}
