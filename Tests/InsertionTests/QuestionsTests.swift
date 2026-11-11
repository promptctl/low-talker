import Darwin
import DarwinCalls
import Foundation
@testable import Insertion
import TestProbes
import Testing

/// The two questions a held Return asks the app, over real Mach ports: the input method's
/// `Asker` on one end, the app's `NoticePort` on the other, both in this process, which each
/// believes. [LAW:behavior-not-structure] What is held is what each end is told and when.
@Suite struct QuestionsTests {
    private static let bound = aBudgetTheRunnerCannotSpend

    private static func asker(_ name: String, believing answerer: PeerIdentity? = nil) throws -> Asker {
        Asker(portName: name, answerer: .success(try answerer ?? OwnProcess.identity()))
    }

    @Test(.timeLimit(.minutes(1))) func theFirstQuestionIsAnsweredWithWhatIsOwed() async throws {
        let name = aPortNobodyElseUses()
        let (port, _, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let asker = try Self.asker(name)

        async let asking = onAThreadOfItsOwn { asker.owed(at: 12.5, within: Self.bound) }
        let asked = await questions.first { @Sendable _ in true }
        #expect(asked?.question == .owed(at: 12.5))
        #expect(asked?.reply.send(Owing.words) == .delivered)

        #expect(await asking == .success(.words))
        withExtendedLifetime(port) {}
    }

    /// The second question is answered when it is known, and the port's queue is not held for it:
    /// a notice told after it is heard while it is still waiting.
    @Test(.timeLimit(.minutes(1))) func theSecondQuestionDoesNotHoldThePortsQueue() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let asker = try Self.asker(name)

        async let asking = onAThreadOfItsOwn { asker.settled(at: 3, within: Self.bound) }
        let asked = try #require(await questions.first { @Sendable _ in true })
        #expect(asked.question == .settled(at: 3))
        #expect(NoticeSender(portName: name, build: aBuild).tellCursorArrived() == .told)
        #expect(await arrivals.first { @Sendable _ in true } == .heard(.cursorArrived(CursorArrival(pid: getpid(), build: aBuild))))

        #expect(asked.reply.send(Settlement.landed) == .delivered)
        #expect(await asking == .success(.landed))
        withExtendedLifetime(port) {}
    }

    @Test func nobodyListeningIsSaidSo() {
        let name = aPortNobodyElseUses()
        let asker = Asker(portName: name, answerer: .success(.adHoc(cdhash: "00")))
        #expect(asker.owed(at: 1, within: Self.bound) == .failure(.wire(.nobodyIsListening(port: name))))
    }

    /// A question the app drops is an app that has let go of the Return, and the asker hears that
    /// at once instead of waiting out its bound.
    @Test(.timeLimit(.minutes(1))) func aQuestionTheAppDropsIsAbandoned() async throws {
        let name = aPortNobodyElseUses()
        let (port, _, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let asker = try Self.asker(name)

        async let asking = onAThreadOfItsOwn { asker.settled(at: 1, within: Self.bound) }
        // The right is let go of the moment the question's holder is, answered or not.
        _ = await questions.first { @Sendable _ in true }

        #expect(await asking == .failure(.wire(.abandoned(port: name))))
        withExtendedLifetime(port) {}
    }

    /// An asker that waited out its bound has let go of its end, and an answer that comes after is
    /// accepted by the kernel and read by no one: the asker's bound is the whole of what ends a wait.
    @Test(.timeLimit(.minutes(1))) func anAnswerAfterTheAskerGaveUpIsReadByNoOne() async throws {
        let name = aPortNobodyElseUses()
        let (port, _, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let asker = try Self.asker(name)

        async let asking = onAThreadOfItsOwn { asker.settled(at: 1, within: .milliseconds(100)) }
        let asked = try #require(await questions.first { @Sendable _ in true })
        #expect(await asking == .failure(.wire(.noAnswer(port: name, after: .milliseconds(100)))))

        #expect(asked.reply.send(Settlement.landed) == .delivered)
        withExtendedLifetime(port) {}
    }

    /// A process that is not the app is not answered as if it were: the question never reaches the
    /// app's closure, the sender is said by name, and the asker is told the right was dropped.
    @Test(.timeLimit(.minutes(1))) func aSenderThatIsNotTheInputMethodIsNotAnswered() async throws {
        let name = aPortNobodyElseUses()
        let someoneElse = PeerIdentity.signed(identifier: "ai.promptctl.low-talker.test.inputmethod", certificate: String(repeating: "0", count: 40))
        let (port, arrivals, _) = try hostNoticesAndQuestions(name: name, senders: someoneElse)
        let asker = try Self.asker(name)

        #expect(await onAThreadOfItsOwn { asker.owed(at: 1, within: Self.bound) } == .failure(.wire(.abandoned(port: name))))
        guard case .told(let said)? = await arrivals.first(where: { @Sendable _ in true }) else {
            Issue.record("the port heard a sender it was not told to hear")
            return
        }
        #expect(said.contains("ignored a notice told by pid \(getpid())"))
        withExtendedLifetime(port) {}
    }

    /// An answer from anyone but this installation's app is not believed, whatever it says: a name
    /// anyone can compute is a name anyone can register first.
    @Test(.timeLimit(.minutes(1))) func anAnswerFromSomeoneWhoIsNotTheAppIsNotBelieved() async throws {
        let name = aPortNobodyElseUses()
        let (port, _, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let stranger = PeerIdentity.signed(identifier: "ai.promptctl.low-talker.test.app", certificate: String(repeating: "1", count: 40))
        let asker = try Self.asker(name, believing: stranger)

        async let asking = onAThreadOfItsOwn { asker.owed(at: 1, within: Self.bound) }
        let asked = try #require(await questions.first { @Sendable _ in true })
        #expect(asked.reply.send(Owing.nothing) == .delivered)

        guard case .failure(.wire(.answeredByAStranger)) = await asking else {
            Issue.record("an answer from a stranger was believed")
            return
        }
        withExtendedLifetime(port) {}
    }

    /// An asker that cannot say who the app is believes nobody and asks nobody.
    @Test func anAskerThatCannotSayWhoTheAppIsAsksNobody() {
        let asker = Asker(portName: aPortNobodyElseUses(), answerer: .failure(.notValid))
        #expect(asker.owed(at: 1, within: Self.bound) == .failure(.unverifiable(.notValid)))
        #expect(asker.settled(at: 1, within: Self.bound) == .failure(.unverifiable(.notValid)))
    }

    /// A question whose stamp is not a moment on the clock is no question, and is said by name and
    /// never answered as one; the asker's right is released, so it is not left waiting.
    @Test(.timeLimit(.minutes(1))) func aQuestionThatIsNoQuestionIsSaidSo() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals, _) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        var remote = mach_port_t()
        try #require(lt_bootstrap_look_up(name, &remote) == KERN_SUCCESS)
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let junk = Data("not a stamp".utf8)

        let sent = Mach.send(
            junk, id: Wire.owed, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: Mach.noPort, timeout: Self.bound)
        try #require(sent == MACH_MSG_SUCCESS)

        #expect(await arrivals.first { @Sendable _ in true } == .told(NoticePort.Event.notUnderstood(id: Wire.owed, bytes: junk.count).description))
        withExtendedLifetime(port) {}
    }

    @Test func aStampIsAFiniteMomentOnTheClock() {
        #expect(Wire.question(id: Wire.owed, payload: Wire.stamp(7.25)) == .owed(at: 7.25))
        #expect(Wire.question(id: Wire.settled, payload: Wire.stamp(0)) == .settled(at: 0))
        #expect(Wire.question(id: Wire.panel, payload: Wire.stamp(4.5)) == .panel(at: 4.5))
        #expect(Wire.question(id: Wire.panel, payload: Wire.stamp(1e12)) == nil)
        #expect(Wire.question(id: Wire.panel, payload: nil) == nil)
        #expect(Wire.question(id: Wire.settled, payload: Wire.stamp(-1)) == nil)
        #expect(Wire.question(id: Wire.settled, payload: Wire.stamp(1e12)) == nil)
        #expect(Wire.question(id: Wire.owed, payload: nil) == nil)
        #expect(Wire.question(id: Wire.owed, payload: Data("{}".utf8)) == nil)
        #expect(Wire.question(id: Wire.cursorArrived, payload: Wire.stamp(1)) == nil)
    }

    @Test func theAnswersCrossAsTheValuesThatWereSent() {
        for owing in [Owing.nothing, .words] { #expect(Wire.owing(of: Wire.owing(owing)) == owing) }
        for settlement in [Settlement.landed, .notLanded] { #expect(Wire.settlement(of: Wire.settlement(settlement)) == settlement) }
        for panel in [PanelState.shut, .shown] { #expect(Wire.panelState(of: Wire.panelState(panel)) == panel) }
        #expect(Wire.owing(of: Wire.settlement(.landed)) == nil)
        #expect(Wire.panelState(of: Wire.settlement(.landed)) == nil)
    }

    /// The question an Escape asks is answered with whether the word box is open, over the real port.
    @Test(.timeLimit(.minutes(1))) func thePanelQuestionIsAnsweredWithWhetherTheBoxIsOpen() async throws {
        let name = aPortNobodyElseUses()
        let (port, _, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let asker = try Self.asker(name)

        async let asking = onAThreadOfItsOwn { asker.panel(at: 8, within: Self.bound) }
        let asked = try #require(await questions.first { @Sendable _ in true })
        #expect(asked.question == .panel(at: 8))
        #expect(asked.reply.send(PanelState.shown) == .delivered)

        #expect(await asking == .success(.shown))
        withExtendedLifetime(port) {}
    }
}
