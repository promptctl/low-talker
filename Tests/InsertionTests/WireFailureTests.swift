import Darwin
import DarwinCalls
import Foundation
@testable import Insertion
import TestProbes
import Testing

/// An insert and a question cross one round trip, so a far end that fails one fails the other the
/// same way, and both say it with the same `WireFailure`. Each row puts one far end on a name and
/// sends it an insert, then puts the same far end on another name and asks it a question. What
/// the far end does to the first message it receives is the whole of the row: for an insert that
/// is the greeting, for a question the question. [LAW:single-enforcer]
@Suite(.timeLimit(.minutes(1))) struct WireFailureTests {
    /// What the far end does with the first message it receives.
    enum FarEnd: Sendable, CustomStringConvertible {
        case absent
        case drops
        case keeps
        case answersGarbled
        /// Answers, and is not the process the asker believes.
        case answersAsAStranger

        var description: String {
            switch self {
            case .absent: "nobody holds the name"
            case .drops: "it drops the message unanswered"
            case .keeps: "it keeps the message unanswered"
            case .answersGarbled: "it answers bytes in no shape either end reads"
            case .answersAsAStranger: "it answers, and is not who the asker believes"
            }
        }
    }

    static let phase = Duration.milliseconds(200)
    static let stranger = PeerIdentity.adHoc(cdhash: String(repeating: "0", count: 40))

    /// The failure `farEnd` on `name` causes, whichever message it was handed.
    static func failure(_ farEnd: FarEnd, on name: String) throws -> WireFailure {
        switch farEnd {
        case .absent: .nobodyIsListening(port: name)
        case .drops: .abandoned(port: name)
        case .keeps: .noAnswer(port: name, after: phase)
        case .answersGarbled: .notReadable(port: name, bytes: 8)
        case .answersAsAStranger: .answeredByAStranger(port: name, pid: getpid(), because: .someoneElse(try OwnProcess.identity()), required: stranger)
        }
    }

    /// `farEnd` on a fresh name, for as long as `body` runs.
    static func hosting<T>(_ farEnd: FarEnd, _ body: (String) async throws -> T) async throws -> T {
        let name = aPortNobodyElseUses()
        guard case .absent = farEnd else {
            let right = try ReceiveRight(sendable: true)
            try #require(lt_bootstrap_register(name, right.port) == KERN_SUCCESS)
            let done = DispatchSemaphore(value: 0)
            defer { done.signal() }
            Thread {
                guard case .received(let message) = Mach.receive(on: right.port, timeout: aBudgetTheRunnerCannotSpend) else { return }
                switch farEnd {
                case .absent, .drops: message.discardReply()
                case .keeps: done.wait(); message.discardReply()
                case .answersGarbled, .answersAsAStranger: _ = message.answer(Data("nonsense".utf8))
                }
            }.start()
            defer { withExtendedLifetime(right) {} }
            return try await body(name)
        }
        return try await body(name)
    }

    static func believed(_ farEnd: FarEnd) throws -> PeerIdentity {
        if case .answersAsAStranger = farEnd { stranger } else { try OwnProcess.identity() }
    }

    @Test(arguments: [FarEnd.absent, .drops, .keeps, .answersGarbled, .answersAsAStranger])
    func anInsertAndAQuestionFailTheSameWay(farEnd: FarEnd) async throws {
        let answerer = try Self.believed(farEnd)
        let (insertName, inserted): (String, Result<Int, InsertFailure>) = try await Self.hosting(farEnd) { name in
            let inserter = InputMethodInserter(portName: name, timeout: Self.phase * 4, answerer: .success(answerer))
            do throws(InsertFailure) {
                return (name, .success(try await inserter.insert("hello", into: .cursorInFront).characters))
            } catch { return (name, .failure(error)) }
        }
        let (questionName, asked) = try await Self.hosting(farEnd) { name in
            let asker = Asker(portName: name, answerer: .success(answerer))
            return (name, await onAThreadOfItsOwn { asker.owed(at: 1, within: Self.phase) })
        }

        #expect(inserted == .failure(.unreachable(Unreachable(try Self.failure(farEnd, on: insertName), at: .greeting))))
        #expect(asked == .failure(.wire(try Self.failure(farEnd, on: questionName))))
    }
}
