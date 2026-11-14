import Foundation
import Insertion
import InsertionFakes
import LowTalkerCore
import LowTalkerCoreFakes
import TestProbes
import Testing

/// The config source's contract, on the fake and on a real file of its own.
@Suite struct ConfigSourceContractTests {
    static let fake = ConfigSourceContract {
        let file = FakeConfigFile()
        return (file, { file.save($0) })
    }

    static let file = ConfigSourceContract {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "config.toml")
        return (ConfigFileSource(url: url), { text in
            guard let text else { return try FileManager.default.removeItem(at: url) }
            try text.write(to: url, atomically: true, encoding: .utf8)
        })
    }

    @Test(arguments: ConfigSourceContract.Statement.allCases)
    func theFakeKeepsTheContract(_ statement: ConfigSourceContract.Statement) async throws {
        #expect(try await Self.fake.disagreements(with: statement) == [])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ConfigSourceContract.Statement.allCases)
    func theFileKeepsTheContract(_ statement: ConfigSourceContract.Statement) async throws {
        #expect(try await Self.file.disagreements(with: statement) == [])
    }
}

/// The notice host's contract, on the fake and on a real port of its own.
@MainActor @Suite struct NoticeHostContractTests {
    static let fake = NoticeHostContract {
        let host = FakeNoticeHost()
        return (host, { @Sendable in Task { @MainActor in host.tellCursorArrived() } }, { @Sendable in
            let reply = FakeReply()
            await host.ask(.owed(at: NoticeHostContract.asked), through: reply)
            guard case .owing(let owing) = await reply.said() else { preconditionFailure("asked what is owed, answered otherwise") }
            return .success(owing)
        })
    }

    static let port = NoticeHostContract {
        let name = "ai.promptctl.low-talker.test.notices.\(getpid()).\(UUID().uuidString)"
        let host = InputMethodNotices.Host(portName: name) { () throws(PortNotHosted) in
            do throws(PeerIdentity.Unreadable) { return try PeerIdentity.ofThisProcess() } catch { throw .noRequirement(error) }
        }
        return (host, { _ = NoticeSender(portName: name, build: nil).tellCursorArrived() }, { @Sendable in
            // Asked from a thread of its own, as the input method asks: the round trip blocks.
            await onAThreadOfItsOwn {
                Asker(portName: name, answerer: Result { () throws(PeerIdentity.Unreadable) in try .ofThisProcess() })
                    .owed(at: NoticeHostContract.asked, within: .seconds(10))
            }
        })
    }

    @Test(arguments: NoticeHostContract.Statement.allCases)
    func theFakeKeepsTheContract(_ statement: NoticeHostContract.Statement) async {
        #expect(await Self.fake.disagreements(with: statement) == [])
    }

    @Test(.timeLimit(.minutes(1)), arguments: NoticeHostContract.Statement.allCases)
    func thePortKeepsTheContract(_ statement: NoticeHostContract.Statement) async {
        #expect(await Self.port.disagreements(with: statement) == [])
    }
}

/// The model supply's contract, on the fake.
@Suite struct ModelSupplyContractTests {
    static let fake = ModelSupplyContract { FakeModelSupply { turns in FakeTranscriber(turns: turns) { _ in Transcript(typed: "") } } }

    @Test(arguments: ModelSupplyContract.Statement.allCases)
    func theFakeKeepsTheContract(_ statement: ModelSupplyContract.Statement) async throws {
        #expect(try await Self.fake.disagreements(with: statement) == [])
    }
}
