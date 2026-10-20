import Darwin
import DarwinCalls
import Foundation
@testable import Insertion
import Testing

/// What the hotkey port did, in the order it did it, for a case to wait on.
private enum Arrival: Equatable {
    case cursorArrived(CursorArrival)
    case told(String)
}

/// The app's end of the hotkey port on `name`, hearing `senders`, with everything it does
/// arriving on the stream it hands back.
private func hostNotices(name: String, senders: PeerIdentity) throws -> (port: NoticePort, arrivals: AsyncStream<Arrival>) {
    let (arrivals, continuation) = AsyncStream<Arrival>.makeStream()
    let port = try NoticePort(
        portName: name, senders: senders, queue: DispatchQueue(label: name),
        told: { continuation.yield(.told($0.description)) }, cursorArrived: { continuation.yield(.cursorArrived($0)) })
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
        #expect(arrived == Array(repeating: .cursorArrived(CursorArrival(pid: getpid(), build: aBuild)), count: 3))
        withExtendedLifetime(port) {}
    }

    /// An input method whose bundle carries no build tells its arrivals without one, as every
    /// input method from before builds were compared does, and the app hears that it said none.
    @Test(.timeLimit(.minutes(1))) func anArrivalWithoutABuildIsHeardSayingNone() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        #expect(NoticeSender(portName: name, build: nil).tellCursorArrived() == .told)
        #expect(await arrivals.first(where: { _ in true }) == .cursorArrived(CursorArrival(pid: getpid(), build: nil)))
        withExtendedLifetime(port) {}
    }

    /// A cursor arrival carries a build or nothing, so one carrying other bytes is not one.
    @Test func aCursorArrivalCarryingBytesThatAreNoBuildIsNotOne() {
        #expect(Wire.arrival(id: Wire.cursorArrived, payload: nil) == .some(nil))
        #expect(Wire.arrival(id: Wire.cursorArrived, payload: Data()) == .some(nil))
        #expect(Wire.arrival(id: Wire.cursorArrived, payload: Wire.said(aBuild)) == .some(aBuild))
        #expect(Wire.arrival(id: Wire.cursorArrived, payload: Data([1])) == nil)
        #expect(Wire.arrival(id: Wire.greeting, payload: Wire.said(aBuild)) == nil)
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
