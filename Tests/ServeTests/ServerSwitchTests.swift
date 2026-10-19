import Foundation
import LowTalkerCore
import Network
@testable import Serve
import Synchronization
import Testing

/// The app's server as the person switches it (low-serve-axq.tom): off until chosen, the
/// choice kept, the port held only while on, and every request answered with the engine the
/// app hands it.
@MainActor @Suite final class ServerSwitchTests {
    /// A defaults domain no other test, and no installation, reads, gone once the test is.
    /// Named by a path, so its plist is written there rather than into ~/Library/Preferences,
    /// where removing the domain would leave the file behind.
    let domain = FileManager.default.temporaryDirectory.appendingPathComponent("ServerSwitchTests-\(UUID().uuidString)")
    lazy var defaults = UserDefaults(suiteName: domain.path)!
    /// The port the switch's first listen was given, which every listen after it asks for
    /// again, as the app's fixed port would be.
    let held = HeldPort()

    deinit {
        try? FileManager.default.removeItem(at: domain.appendingPathExtension("plist"))
    }

    /// A switch over this test's defaults, listening on loopback.
    func aSwitch() -> ServerSwitch {
        ServerSwitch(defaults: defaults) { [held] binding, engine throws(ListenRefused) in
            let server = try await TranscriptionServer.listen(at: ListenAddress(binding: binding, port: held.port.withLock { $0 }), engine: engine, record: { _ in })
            held.port.withLock { $0 = server.port }
            return server
        }
    }

    @Test func offUntilChosenAndBindsNothing() async throws {
        let server = aSwitch()
        server.resume(at: .success(.loopback))
        #expect(!server.chosen)
        #expect("\(server.state)" == "off")
        #expect(server.running == nil)
    }

    /// Answered with whatever the app last handed it: 503 while its model loads, then the
    /// model itself.
    @Test func chosenItListensAndAnswersWithTheEngineItIsHanded() async throws {
        let server = aSwitch()
        defer { server.choose(false, at: .success(.loopback)) }
        server.choose(true, at: .success(.loopback))
        let running = try await listening(server)
        let upload: [(name: String, filename: String?, value: Data)] = [
            ("model", nil, Data("m".utf8)), ("response_format", nil, Data("text".utf8)), ("file", "audio.mp3", try fixture("hello-16k-mono.mp3")),
        ]
        #expect(try await running.post(upload).0.statusCode == 503)
        server.answer(with: .ready(Stub()))
        let (response, body) = try await running.post(upload)
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "Hello world, this is LowTalker.\n")
        #expect("\(server.state)" == "listening at \(running.base)")
    }

    /// Switched off, the port is let go and the choice is remembered as off.
    @Test func switchedOffItLetsThePortGo() async throws {
        let server = aSwitch()
        server.choose(true, at: .success(.loopback))
        let port = try await listening(server).server.port
        server.choose(false, at: .success(.loopback))
        await server.running?.value
        #expect("\(server.state)" == "off")
        #expect(!aSwitch().chosen)
        let again = try await TranscriptionServer.listen(at: ListenAddress(port: port), engine: { .ready(Stub()) }, record: { _ in })
        again.stop()
    }

    /// The choice outlives the switch, as it outlives the app: another switch over the same
    /// defaults resumes listening.
    @Test func theChoiceIsKept() async throws {
        aSwitch().choose(true, at: .failure(.noModes))
        let resumed = aSwitch()
        defer { resumed.choose(false, at: .success(.loopback)) }
        resumed.resume(at: .success(.loopback))
        _ = try await listening(resumed)
    }

    /// Asked again while listening, it listens again on its own port, over what the server
    /// it replaces leaves there: the TIME_WAIT of a request it answered and closed, and a
    /// Realtime socket a client still holds, which goes on being served (low-serve-28l). A
    /// plain bind() is refused over either; NWListener binds over both with
    /// `allowLocalEndpointReuse` false.
    @Test(.timeLimit(.minutes(1))) func aRestartListensAgainOnTheSamePort() async throws {
        let server = aSwitch()
        defer { server.choose(false, at: .success(.loopback)) }
        server.answer(with: .ready(Stub()))
        server.choose(true, at: .success(.loopback))
        let running = try await listening(server)
        // Answered with `connection: close`, so the server's side closes first.
        _ = try await running.post(Data())
        var client = Client(running)
        defer { client.task.cancel(with: .normalClosure, reason: nil) }
        _ = try await client.until("session.created")
        server.resume(at: .success(.loopback))
        #expect(try await listening(server).server.port == running.server.port)
        try await client.send(["type": "session.update", "session": [:] as [String: Any]])
        _ = try await client.until("session.updated")
    }

    /// Switched off while it was still binding, the listen that answers late lets its port go
    /// rather than being left up behind a switch that reads off.
    @Test func switchedOffWhileStartingNothingIsLeftListening() async throws {
        let server = aSwitch()
        server.choose(true, at: .success(.loopback))
        server.choose(false, at: .success(.loopback))
        await server.running?.value
        #expect("\(server.state)" == "off")
        let again = try await TranscriptionServer.listen(at: ListenAddress(port: held.port.withLock { $0 }), engine: { .ready(Stub()) }, record: { _ in })
        again.stop()
    }

    /// An address no interface holds keeps the listen waiting for one; switched off, it is
    /// given up, and switched on again elsewhere, it listens there rather than waiting behind it.
    @Test(.timeLimit(.minutes(1))) func aListenWaitingForItsAddressIsGivenUp() async throws {
        // TEST-NET-1, which no interface of any Mac holds.
        let unheld = ServeBinding.interface(try InterfaceAddress("192.0.2.1"), token: try BearerToken("sk-test-token"))
        let server = aSwitch()
        defer { server.choose(false, at: .success(.loopback)) }
        server.choose(true, at: .success(unheld))
        try await Task.sleep(for: .milliseconds(200))
        #expect("\(server.state)" == "starting")
        server.choose(false, at: .success(unheld))
        await server.running?.value
        #expect("\(server.state)" == "off")
        server.choose(true, at: .success(.loopback))
        _ = try await listening(server)
    }

    /// An address another process holds, and a config that names none, each leave the switch
    /// on and the server stopped, saying why.
    @Test func whatKeepsItFromListeningIsSaid() async throws {
        let holder = try await TranscriptionServer.listen(at: ListenAddress(port: .any), engine: { .ready(Stub()) }, record: { _ in })
        defer { holder.stop() }
        held.port.withLock { $0 = holder.port }
        let taken = aSwitch()
        taken.choose(true, at: .success(.loopback))
        await taken.running?.value
        #expect("\(taken.state)".hasPrefix("stopped — LowTalker cannot serve on 127.0.0.1:\(holder.port): "))
        #expect(taken.chosen)

        let unread = aSwitch()
        unread.choose(true, at: .failure(.noModes))
        await unread.running?.value
        #expect("\(unread.state)" == "stopped — the config cannot be read: \(ConfigError.noModes)")
    }

    /// Waits until the switch reads listening, and returns its server.
    func listening(_ server: ServerSwitch) async throws -> Running {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            switch server.state {
            case .listening(let listener): return Running(server: listener, events: AsyncStream { $0.finish() })
            case .stopped(let reason): throw ListenFailed(reason: reason)
            case .off, .starting: try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw ListenFailed(reason: "still \(server.state) after 30 s")
    }
}

struct ListenFailed: Error, CustomStringConvertible {
    let reason: String
    var description: String { "the switch did not listen: \(reason)" }
}

final class HeldPort: Sendable {
    let port = Mutex(NWEndpoint.Port.any)
}
