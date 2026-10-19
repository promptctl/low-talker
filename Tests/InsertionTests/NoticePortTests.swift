import Darwin
import DarwinCalls
import Foundation
@testable import Insertion
import Testing

/// What the hotkey port did, in the order it did it, for a case to wait on.
private enum Arrival: Equatable {
    case heard(Notice)
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

private let rightOptionHeld = HeldModifiers(flags: 0x80140, uptimeNanoseconds: 1_000_000_000, typedUptimeNanoseconds: 400_000_000)

/// The modifier keys cross from the input method to the app whole, in order, and from the
/// input method alone.
///
/// Both ends run in this process, which the port is told to hear: the check that matters is
/// that a sender it was not told to hear is not heard, and that is a different sender, not a
/// different process. [LAW:behavior-not-structure]
@Suite struct NoticePortTests {
    /// The session sets the secondary-Fn bit while an arrow key is down, and an arrow key is
    /// not Fn; the Fn key down with nothing else is Fn. Every other bit is the session's.
    /// The log line says what was held whenever that is not the session's flags as given.
    @Test func theFnBitIsTheFnKeyItself() {
        let fn: UInt64 = 0x800000
        let anArrowWithRightOption = SessionModifiers(session: 0x80140 | fn, fnKeyDown: false, changedAt: 2.5, typedAt: 1.5)
        #expect(anArrowWithRightOption.flags == 0x80140)
        #expect(anArrowWithRightOption.description == "session 0x880140, Fn key up, held 0x80140, changed at 2.5, typed at 1.5")
        let fnAlone = SessionModifiers(session: 0x100 | fn, fnKeyDown: true, changedAt: 2.5, typedAt: 1.5)
        #expect(fnAlone.flags == 0x100 | fn)
        #expect(fnAlone.description == "session 0x800100, Fn key down, changed at 2.5, typed at 1.5")
        #expect(SessionModifiers(session: 0x80140, fnKeyDown: true, changedAt: 2.5, typedAt: 1.5).flags == 0x80140 | fn)
        #expect(SessionModifiers(session: 0x100, fnKeyDown: false, changedAt: 2.5, typedAt: nil).description
            == "session 0x100, Fn key up, changed at 2.5, a key typed since")
    }

    /// A reading is dated by the session's last change, unless that change came after the
    /// keys were read, or the session reports one from before the event it answers.
    @Test func aReadingIsDatedBetweenItsEventAndTheRead() {
        #expect(SessionModifiers.date(lastChange: 7_000.4, after: 7_000.1, readAt: 7_000.5) == 7_000.4)
        #expect(SessionModifiers.date(lastChange: 7_000.6, after: 7_000.1, readAt: 7_000.5) == 7_000.5)
        #expect(SessionModifiers.date(lastChange: 7_000.5 - 1.8e10, after: 7_000.1, readAt: 7_000.5) == 7_000.1)
        #expect(SessionModifiers.date(lastChange: 7_000.5 - 1.8e10, after: 0, readAt: 7_000.5) == 0)
    }

    /// A key typed counts only before the event the reading answers, by the event's own stamp:
    /// Right Option up at 7_000.4 with an A at 7_000.2 places the A; Return at 7_000.5, after
    /// the release and before a Shift that dates the reading, places nothing, since it hides
    /// whatever was typed before it. A reading answering no event places no key, and a session
    /// that reports a key before the machine came up has typed none since.
    @Test func aKeyTypedIsPlacedOnlyBeforeTheEventTheReadingAnswers() {
        #expect(SessionModifiers.typed(lastKeyDown: 7_000.2, before: 7_000.4) == 7_000.2)
        #expect(SessionModifiers.typed(lastKeyDown: 7_000.5, before: 7_000.4) == nil)
        #expect(SessionModifiers.typed(lastKeyDown: 7_000.2, before: 0) == nil)
        #expect(SessionModifiers.typed(lastKeyDown: -0.5, before: 7_000.4) == 0)
    }

    /// A reading from the session now is dated no later than it was taken, and so is the key
    /// it says was last typed.
    @Test func aLiveReadingIsDatedNoLaterThanItIsTaken() {
        let answering = ProcessInfo.processInfo.systemUptime
        let reading = SessionModifiers.read(after: answering)
        let taken = ProcessInfo.processInfo.systemUptime
        #expect(0...taken ~= reading.changedAt)
        #expect(reading.typedAt.map { 0..<answering ~= $0 } != false)
        #expect(SessionModifiers.read().typedAt == nil)
    }

    @Test func heldModifiersSurviveTheWire() {
        #expect(Wire.heldModifiers(of: Wire.modifiers(rightOptionHeld)) == rightOptionHeld)
        let nothingTypedBefore = HeldModifiers(flags: 0x100, uptimeNanoseconds: 2, typedUptimeNanoseconds: nil)
        #expect(Wire.heldModifiers(of: Wire.modifiers(nothingTypedBefore)) == nothingTypedBefore)
        #expect(Wire.heldModifiers(of: Data(repeating: 0, count: 23)) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func changesAreHeardWholeAndInTheOrderTold() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        let told: [HeldModifiers] = (0..<3).map { (n: UInt64) in
            HeldModifiers(flags: 0x100 | n << 6, uptimeNanoseconds: n, typedUptimeNanoseconds: n == 1 ? nil : n)
        }
        let sender = NoticeSender(portName: name)
        #expect(told.map { sender.tell(.modifiersMoved($0)) } == Array(repeating: .told, count: 3))
        var arrived: [Arrival] = []
        for await arrival in arrivals.prefix(3) { arrived.append(arrival) }
        #expect(arrived == told.map { .heard(.modifiersMoved($0)) })
        withExtendedLifetime(port) {}
    }

    /// A cursor arriving crosses between the changes around it, in the order told, and a
    /// cursor arrival carrying bytes is not one.
    @Test(.timeLimit(.minutes(1))) func aCursorArrivingIsHeardInItsPlace() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        let told: [Notice] = [.modifiersMoved(rightOptionHeld), .cursorArrived, .modifiersMoved(HeldModifiers(flags: 0x100, uptimeNanoseconds: 2, typedUptimeNanoseconds: 1))]
        #expect(told.map(NoticeSender(portName: name).tell) == Array(repeating: .told, count: 3))
        var arrived: [Arrival] = []
        for await arrival in arrivals.prefix(3) { arrived.append(arrival) }
        #expect(arrived == told.map(Arrival.heard))
        #expect(Wire.notice(id: Wire.cursorArrived, payload: Data([1])) == nil)
        withExtendedLifetime(port) {}
    }

    /// The name is one anyone can compute, and a change heard from anyone is a press anyone
    /// can fake: a sender that is not the one named is said by name and never heard.
    @Test(.timeLimit(.minutes(1))) func aSenderThatIsNotTheInputMethodIsNotHeard() async throws {
        let name = aPortNobodyElseUses()
        let someoneElse = PeerIdentity.signed(identifier: "ai.promptctl.low-talker.test.inputmethod", certificate: String(repeating: "0", count: 40))
        let (port, arrivals) = try hostNotices(name: name, senders: someoneElse)
        #expect(NoticeSender(portName: name).tell(.modifiersMoved(rightOptionHeld)) == .told)
        guard case .told(let said)? = await arrivals.first(where: { _ in true }) else {
            Issue.record("the port heard a sender it was not told to hear")
            return
        }
        #expect(said.contains("ignored a notice told by pid \(getpid())"))
        #expect(said.contains(someoneElse.description))
        withExtendedLifetime(port) {}
    }

    /// Bytes that are not held modifiers are said, not dropped.
    @Test(.timeLimit(.minutes(1))) func aMessageThatIsNotHeldModifiersIsSaidSo() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostNotices(name: name, senders: try OwnProcess.identity())
        var remote = mach_port_t()
        try #require(lt_bootstrap_look_up(name, &remote) == KERN_SUCCESS)
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let sent = Mach.send(
            Data("not modifiers".utf8), id: Wire.modifiers, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: Mach.noPort, timeout: aBudgetTheRunnerCannotSpend)
        try #require(sent == MACH_MSG_SUCCESS)
        #expect(await arrivals.first(where: { _ in true }) == .told(NoticePort.Event.notUnderstood(id: Wire.modifiers, bytes: 13).description))
        withExtendedLifetime(port) {}
    }

    @Test func aChangeWithNobodyListeningSaysSo() {
        let name = aPortNobodyElseUses()
        #expect(NoticeSender(portName: name).tell(.modifiersMoved(rightOptionHeld)) == .nobodyIsListening(port: name))
    }

    /// The app hosts the name again each time it rebuilds its hotkey, straight after letting
    /// the last one go, so a released port has given its name up by the time the release
    /// returns. [LAW:no-ambient-temporal-coupling]
    @Test func aReleasedPortsNameCanBeHostedAgainAtOnce() throws {
        let name = aPortNobodyElseUses()
        for _ in 0..<50 {
            _ = try hostNotices(name: name, senders: try OwnProcess.identity())
        }
    }
}
