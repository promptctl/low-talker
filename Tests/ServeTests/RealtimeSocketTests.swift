import Foundation
import LowTalkerCore
@testable import Serve
import Synchronization
import Testing

private func update(_ input: [String: Any]) -> [String: Any] {
    ["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]]
}

@Suite struct RealtimeSocketTests {
    /// Server-side turn detection is refused by name, and the socket stays open: the same
    /// socket then transcribes a turn the client commits.
    @Test func refusesServerVADAndStaysOpen() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        _ = try await client.until("session.created")
        try await client.send(update(["turn_detection": ["type": "server_vad"]]))
        let refusal = try await client.until("error")
        let detail = try #require(refusal["error"] as? [String: Any])
        #expect(detail["code"] as? String == "invalid_value")
        #expect(detail["param"] as? String == "session.audio.input.turn_detection")
        try await client.append(seconds: 1)
        try await client.send(["type": "input_audio_buffer.commit"])
        let completed = try await client.until("conversation.item.input_audio_transcription.completed")
        #expect(completed["transcript"] as? String == "Hello world, this is LowTalker.")
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// A committed turn no sample of which reached the audible floor is answered as OpenAI
    /// answers a turn with nothing said in it: completed, with an empty transcript, and never
    /// failed (low-serve-7t8). The socket's event counts it.
    @Test func aSilentTurnIsCompletedWithNothingSaid() async throws {
        let running = try await Running.start(.ready(Stub(quiet: Quiet(letGo: 1, room: 0.002, refusedAsRoom: 0, transients: .none, range: nil, keptOut: nil, keptOutFrames: 0))))
        defer { running.server.stop() }
        var client = Client(running)
        // 100 of 32767, about -50 dBFS: a quiet room, under the -40 dBFS floor.
        try await client.append(seconds: 1, peak: 100)
        try await client.send(["type": "input_audio_buffer.commit"])
        let completed = try await client.until("conversation.item.input_audio_transcription.completed")
        #expect(completed["transcript"] as? String == "")
        #expect(completed["usage"] as? [String: AnyHashable] == ["type": "duration", "seconds": 1])
        #expect(!client.types().contains("conversation.item.input_audio_transcription.failed"))
        #expect(!client.types().contains("conversation.item.input_audio_transcription.delta"))
        client.task.cancel(with: .normalClosure, reason: nil)
        let realtime = try #require(try await running.nextEvent().realtime)
        #expect(realtime.sent.completed == 1 && realtime.sent.failed == 0 && realtime.sent.nothingSpoken == 1)
        // The 100 appended, as the 16 kHz audio the engine is handed peaks at it.
        #expect(abs(try #require(realtime.sent.nothingSpokenPeak) - 100.0 / 32_767) < 0.0002)
        // The quiet the engine refused it with, the room it heard included.
        #expect(realtime.sent.quietSeconds == 1 && realtime.sent.roomPeak == Double(Float(0.002)))
    }

    /// An engine failure fails its item, not the session: no `error` event, which Pipecat
    /// would take as fatal.
    @Test func anEngineFailureFailsTheItemAndNotTheSession() async throws {
        let running = try await Running.start(.ready(Stub(.failure(.engine(StubFailure())))))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 0.5)
        try await client.send(["type": "input_audio_buffer.commit"])
        let failed = try await client.until("conversation.item.input_audio_transcription.failed")
        let detail = try #require(failed["error"] as? [String: Any])
        #expect(detail["type"] as? String == "server_error")
        #expect((detail["message"] as? String)?.contains("the stub engine was told to fail") == true)
        #expect(!client.types().contains("error"))
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// The prompt a session is updated with is the vocabulary its next item is heard with,
    /// and the language and model are echoed back.
    @Test func thePromptIsTheItemsVocabulary() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.send(update(["transcription": ["model": "gpt-realtime-whisper", "language": "en", "prompt": "LowTalker"], "turn_detection": NSNull()]))
        let updated = try await client.until("session.updated")
        let echoed = try #require(((updated["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any])
        #expect(echoed["transcription"] as? [String: String] == ["model": "gpt-realtime-whisper", "language": "en", "prompt": "LowTalker"])
        try await client.append(seconds: 0.3)
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        #expect(stub.heard.withLock { $0.first?.vocabulary } == Vocabulary([try Vocabulary.Term("LowTalker")]))
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// An event the server does not know is refused naming its type, and nothing else ends.
    @Test func anUnknownEventIsRefusedByType() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.send(["type": "response.create", "event_id": "event_client_1"])
        let refusal = try #require(try await client.until("error")["error"] as? [String: Any])
        #expect(refusal["param"] as? String == "type")
        #expect(refusal["event_id"] as? String == "event_client_1")
        try await client.send(update([:]))
        _ = try await client.until("session.updated")
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// Two turns on one socket are two items, the second following the first.
    @Test func eachCommitIsAnItemFollowingTheLast() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 0.3)
        try await client.send(["type": "input_audio_buffer.commit"])
        let first = try await client.until("input_audio_buffer.committed")
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        try await client.append(seconds: 0.3)
        try await client.send(["type": "input_audio_buffer.commit"])
        let second = try await client.until("input_audio_buffer.committed")
        #expect(first["previous_item_id"] is NSNull)
        #expect(second["previous_item_id"] as? String == first["item_id"] as? String)
        #expect(second["item_id"] as? String != first["item_id"] as? String)
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// The socket's one event says what happened on it, the passes the engine failed to read
    /// during its items included (low-reliability-z2z.5s1).
    @Test func theSocketsEventCountsWhatHappenedOnIt() async throws {
        let running = try await Running.start(.ready(Stub(quiet: Quiet(letGo: 1.5, room: 0.25, refusedAsRoom: 0.5, transients: Transients(count: 2, longest: 0.03), range: 0.5, keptOut: 0.75, keptOutFrames: 3), unread: Partial.Unread(passes: 1, latest: .unreadable(.speechWithoutWords(text: " secret"))))))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 1)
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("error")
        client.task.cancel(with: .normalClosure, reason: nil)
        let event = try await running.nextEvent()
        let realtime = try #require(event.realtime)
        #expect(event.status == 101 && event.path == "/v1/realtime" && event.lost == nil)
        #expect(realtime.appends == 10 && realtime.items == 1 && realtime.closeCode == 1000)
        #expect(abs(realtime.audioSeconds - 1) < 0.01)
        #expect(realtime.sent.completed == 1 && realtime.sent.errors == 1 && realtime.sent.deltas >= 2)
        #expect(realtime.refusals == ["input_audio_buffer_commit_empty": 1] && realtime.refusedAudioSeconds == nil)
        #expect(realtime.sent.quietSeconds == 1.5)
        #expect(realtime.sent.roomPeak == 0.25 && realtime.sent.refusedAsRoomSeconds == 0.5)
        #expect(realtime.sent.transients == 2 && realtime.sent.longestTransientSeconds == 0.03)
        #expect(realtime.sent.rangePeak == 0.5 && realtime.sent.keptOutPeak == 0.75 && realtime.sent.keptOutFrames == 3)
        #expect(realtime.sent.unreadPasses == 1 && realtime.sent.latestUnreadPass == "WhisperKit returned a segment of 7 characters without word timings")
    }

    /// A client that appends for longer than the limit without a commit, as Pipecat does
    /// through silence between turns, is never refused: the open item starts over from its
    /// newest audio each time it outgrows its share, so the socket never holds more than the
    /// limit, and the item committed at last is heard with no more than its share. Each item
    /// let go is cancelled. Limit 4 s: a share of 2 s, of which 1 s is kept, so 10 s
    /// uncommitted lets go 1 s eight times. What an item let go held is free only once its
    /// cancelled transcribe has ended, and the item that replaces it is heard only then, so
    /// the client keeps pace with the engine as a client appending in real time does: each
    /// second's appends wait for the item they let go to have started (low-tests-ape).
    @Test(.timeLimit(.minutes(1))) func appendingPastTheLimitWithoutACommitStartsTheItemOverAndIsNeverRefused() async throws {
        let stub = Stub()
        let (starts, started) = AsyncStream<Void>.makeStream()
        let running = try await Running.start(.ready(Starting(stub: stub, started: started)), limits: ServedLimits(uploads: 1, sockets: 1, audio: 4))
        defer { running.server.stop() }
        var client = Client(running)
        var heardStarting = starts.makeAsyncIterator()
        try await client.append(seconds: 2)
        for _ in 1...8 {
            try #require(await heardStarting.next() != nil)
            try await client.append(seconds: 1)
        }
        try await client.send(["type": "input_audio_buffer.commit"])
        let committed = try #require(try await client.until("input_audio_buffer.committed")["item_id"] as? String)
        let completed = try await client.until("conversation.item.input_audio_transcription.completed")
        #expect(completed["item_id"] as? String == committed)
        client.task.cancel(with: .normalClosure, reason: nil)
        let heard = stub.heard.withLock { $0 }
        let letGo = heard.filter(\.cancelled)
        #expect(heard.count == 9 && letGo.count == 8 && letGo.allSatisfy { $0.seconds < 2.01 })
        #expect(heard.filter { !$0.cancelled }.map { abs($0.seconds - 2) < 0.01 } == [true])
        let realtime = try #require(try await running.nextEvent().realtime)
        #expect(realtime.appends == 100 && realtime.refusals.isEmpty && realtime.sent.errors == 0)
        #expect(realtime.items == 9 && realtime.itemsLetGo == 8 && abs(realtime.letGoAudioSeconds - 8) < 0.01)
        #expect(realtime.sent.completed == 1 && abs(realtime.audioSeconds - 2) < 0.01)
        #expect(realtime.heldAudioSeconds <= 4 && realtime.heldItems == 1)
    }

    /// An item let go while it waits for the one committed before it is freed at once, not
    /// once that one is answered, so a client appending through silence behind an engine
    /// holding its committed turn is not refused for audio the socket let go. Limit 8 s: a
    /// share of 4 s, of which 2 s is kept. With 1.5 s committed and waiting, 4.1 s starts the
    /// open item over, and 1.9 s more takes the socket to 6.5 s, or 8.5 s had the 2 s let go
    /// stayed held. The update's answer is a barrier past the start-over.
    @Test func anItemLetGoWhileItWaitsItsTurnIsFreedAtOnce() async throws {
        let gated = Gated()
        let running = try await Running.start(.ready(gated), limits: ServedLimits(uploads: 1, sockets: 1, audio: 8))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 0.5)
        try await client.send(["type": "input_audio_buffer.commit"])
        try await client.append(seconds: 4.1)
        try await client.send(update([:]))
        _ = try await client.until("session.updated")
        try await client.append(seconds: 1.9)
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("input_audio_buffer.committed")
        gated.gate.cancel()
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        client.task.cancel(with: .normalClosure, reason: nil)
        let realtime = try #require(try await running.nextEvent().realtime)
        #expect(realtime.refusals.isEmpty && realtime.itemsLetGo == 1 && realtime.sent.completed == 2)
    }

    /// An item let go sends nothing more.
    @Test func anItemLetGoSendsNoMoreDeltas() async {
        let sent = await deltas { outbox in
            let item = Deltas(item: "item_a", outbox: outbox)
            item.heard(Partial(confirmed: timed(2), tentative: Transcript(words: []), repunctuated: 0, unread: nil))
            item.letGo()
            item.heard(Partial(confirmed: timed(4), tentative: Transcript(words: []), repunctuated: 0, unread: nil))
        }
        #expect(sent == [" w1 w2"])
    }

    /// The newest bytes are kept oldest first, whether they arrive in one append or wrap
    /// around the ring across many.
    @Test func newestKeepsTheLastBytesInOrder() {
        var newest = Newest(capacity: 5)
        newest.append(Data([1, 2, 3]))
        #expect(newest.bytes == Data([1, 2, 3]))
        newest.append(Data([4, 5, 6, 7]))
        #expect(newest.bytes == Data([3, 4, 5, 6, 7]))
        newest.append(Data([8, 9, 10, 11, 12, 13, 14]))
        #expect(newest.bytes == Data([10, 11, 12, 13, 14]))
        var none = Newest(capacity: 0)
        none.append(Data([1]))
        #expect(none.bytes.isEmpty)
    }

    /// A socket opened while the server holds its limit of them is refused with a 429 before
    /// it upgrades; the place is given back when a socket closes.
    @Test func aSocketPastTheLimitIsRefusedBeforeItUpgrades() async throws {
        let running = try await Running.start(.ready(Stub()), limits: ServedLimits(uploads: 1, sockets: 1, audio: 60))
        defer { running.server.stop() }
        var open = Client(running)
        _ = try await open.until("session.created")
        let refused = Client(running)
        await #expect(throws: (any Error).self) { try await refused.task.receive() }
        let refusal = try await running.nextEvent()
        #expect(refusal.status == 429 && refusal.error == "rate_limit_exceeded" && refusal.sockets == 1 && refusal.realtime == nil)
        open.task.cancel(with: .normalClosure, reason: nil)
        let closed = try await running.nextEvent()
        #expect(closed.status == 101 && closed.sockets == 1)
        var next = Client(running)
        _ = try await next.until("session.created")
        next.task.cancel(with: .normalClosure, reason: nil)
    }

    /// A socket whose items wait on a held engine goes on reading: each commit is answered,
    /// a ping is answered, and appends are taken until what the socket holds across its
    /// items, their audio and a second for each, would pass the limit. Once the engine is free every item is heard, each only
    /// after the one before it is answered, so they are answered in the order committed, and
    /// the audio they held is free again.
    @Test func aSocketWhoseItemsWaitOnTheEngineKeepsReading() async throws {
        let gated = Gated()
        let running = try await Running.start(.ready(gated), limits: ServedLimits(uploads: 1, sockets: 1, audio: 6))
        defer { running.server.stop() }
        var client = Client(running)
        var committed: [String] = []
        for _ in 0..<3 {
            try await client.append(seconds: 0.5)
            try await client.send(["type": "input_audio_buffer.commit"])
            committed.append(try #require(try await client.until("input_audio_buffer.committed")["item_id"] as? String))
        }
        // URLSession reads a pong only while a receive is pending, so updates are answered
        // one after another until the pong has come in during one of them.
        let pong = Mutex<Result<Void, any Error>?>(nil)
        client.task.sendPing { error in pong.withLock { $0 = error.map { .failure($0) } ?? .success(()) } }
        while pong.withLock({ $0 }) == nil {
            try await client.send(update([:]))
            _ = try await client.until("session.updated")
        }
        try pong.withLock { $0 }!.get()
        try await client.append(seconds: 0.6)
        let refusal = try #require(try await client.until("error")["error"] as? [String: Any])
        #expect(refusal["code"] as? String == "audio_too_long")
        try await client.send(["type": "input_audio_buffer.commit"])
        committed.append(try #require(try await client.until("input_audio_buffer.committed")["item_id"] as? String))
        gated.gate.cancel()
        var completed: [String] = []
        for _ in 0..<4 {
            completed.append(try #require(try await client.until("conversation.item.input_audio_transcription.completed")["item_id"] as? String))
        }
        #expect(completed == committed)
        try await client.append(seconds: 1.5)
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        client.task.cancel(with: .normalClosure, reason: nil)
        #expect(gated.started.withLock { $0 } == [0, 1, 2, 3, 4])
        let realtime = try #require(try await running.nextEvent().realtime)
        #expect(realtime.items == 5 && realtime.sent.completed == 5 && realtime.refusals == ["audio_too_long": 1])
        let refused = try #require(realtime.refusedAudioSeconds)
        #expect(abs(realtime.heldAudioSeconds - 6) < 0.01 && abs(refused - 6.1) < 0.01 && realtime.heldItems == 4)
    }

    /// A client that sends events the server refuses and never reads what it is sent is
    /// read no further once the frames left unsent pass the outbox's limit: its own sends
    /// stall, and the server holds no more than the limit and one message's answer.
    @Test func aClientThatDoesNotReadIsNotRead() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let port = running.server.port.rawValue
        let batch = Data((0..<1_000).flatMap { _ in masked(0x1, Data(#"{"type":"x"}"#.utf8)) })
        // Blocking socket calls, so off the cooperative pool the server runs on.
        let sent = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try NonReadingClient.flood(port: port, with: batch) }) }
        }
        try #require(sent < NonReadingClient.most, "the server read \(sent) bytes from a client that read nothing")
        let event = try await running.nextEvent()
        let realtime = try #require(event.realtime)
        #expect(realtime.backpressureWaits >= 1)
        #expect(realtime.mostUnsentBytes > Outbox.limit && realtime.mostUnsentBytes < Outbox.limit + 4_096)
        #expect(event.lost != nil)
    }

    /// An append that holds no whole sample puts no audio in the buffer, so committing it
    /// is refused as committing nothing is.
    @Test func aCommitWithNoWholeSampleIsRefusedAsEmpty() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        for audio in ["", Data([0x01]).base64EncodedString()] {
            try await client.send(["type": "input_audio_buffer.append", "audio": audio])
        }
        try await client.send(["type": "input_audio_buffer.commit"])
        let refusal = try #require(try await client.until("error")["error"] as? [String: Any])
        #expect(refusal["code"] as? String == "input_audio_buffer_commit_empty")
        #expect(!client.types().contains("input_audio_buffer.committed"))
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// Refused before the upgrade, with a status: a socket is never opened on an engine
    /// that is not there.
    @Test func anUpgradeBeforeTheModelIsResidentIs503() async throws {
        let running = try await Running.start(.notResident("still loading"))
        defer { running.server.stop() }
        let client = Client(running)
        await #expect(throws: (any Error).self) { try await client.task.receive() }
        let event = try await running.nextEvent()
        #expect(event.status == 503 && event.error == "model_not_ready" && event.realtime == nil)
    }
}

@Suite struct WebSocketTests {
    @Test func aFrameNotYetWholeIsNothingYet() throws {
        let frame = masked(0x1, Data("hello".utf8))
        #expect(try WebSocket.parse(frame.prefix(frame.count - 1), limit: 100) == nil)
        #expect(try WebSocket.parse(frame + Data([0x81]), limit: 100)?.consumed == frame.count)
    }

    @Test func fragmentsAreOneMessageAndControlFramesCutIn() throws {
        var assembler = WebSocket.Assembler()
        let frames = [masked(0x1, Data("hel".utf8), final: false), masked(0x9, Data("p".utf8)), masked(0x0, Data("lo".utf8))]
        let messages = try frames.map { try assembler.take(#require(try WebSocket.parse($0, limit: 100)).0, limit: 100) }
        #expect(messages == [nil, .ping(Data("p".utf8)), .text("hello")])
    }

    @Test(arguments: [
        (Data([0x81, 0x00]), UInt16(1002)),
        (Data([0xC1, 0x80, 0, 0, 0, 0]), UInt16(1002)),
        (Data([0x81, 0xFE, 0x10, 0x00, 0, 0, 0, 0]), UInt16(1009)),
    ])
    func aFrameBreakingTheProtocolSaysHow(bytes: Data, code: UInt16) {
        do {
            _ = try WebSocket.parse(bytes, limit: 1024)
            Issue.record("\(bytes as NSData) was read as a frame")
        } catch {
            #expect(error.code == code)
        }
    }

    /// A close frame's code is read off it; one a peer may not send, or a code cut to one
    /// byte, breaks the protocol.
    @Test(arguments: [
        (Data(), Result<UInt16?, WebSocket.Violation>.success(nil)),
        (Data([0x03, 0xE8]) + Data("bye".utf8), .success(1000)),
        (Data([0x03]), .failure(WebSocket.Violation(code: 1002, "a close frame's code was one byte"))),
        (Data([0x03, 0xED]), .failure(WebSocket.Violation(code: 1002, "close code 1005 is not one a peer may send"))),
        (Data([0x03, 0xE8, 0xFF]), .failure(WebSocket.Violation(code: 1007, "a close frame's reason is not UTF-8"))),
    ])
    func aCloseFramesCodeIsParsed(payload: Data, expected: Result<UInt16?, WebSocket.Violation>) throws {
        var assembler = WebSocket.Assembler()
        let frame = try #require(try WebSocket.parse(masked(0x8, payload), limit: 100)).0
        #expect(Result { () throws(WebSocket.Violation) in try assembler.take(frame, limit: 100) } == expected.map { .close($0) })
    }

    /// RFC 6455's own example key and answer.
    @Test func theAcceptKeyIsTheRFCs() {
        #expect(WebSocket.accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

/// A client that upgrades and then only sends. Upgraded with RFC 6455's own example key.
private enum NonReadingClient {
    /// The most bytes it sends before giving up on the server ever stopping reading.
    static let most = 64 << 20
    /// How long the server takes nothing before it counts as having stopped reading: past
    /// the few seconds a CI runner can freeze the test process for.
    static let stall: Int32 = 6_000

    /// Sends `batch` over and over until the server stalls or `most` bytes have gone, then
    /// closes with what it was sent unread, which resets the connection. Returns the bytes
    /// sent.
    static func flood(port: UInt16, with batch: Data) throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        // A write after the server resets fails with EPIPE rather than killing the process.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw failure() }
        try upgrade(descriptor)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var sent = 0
        while sent < most, try send(batch, descriptor) { sent += batch.count }
        return sent
    }

    /// Sends the upgrade and reads up to the end of the 101, and nothing after it.
    private static func upgrade(_ descriptor: Int32) throws {
        let request = "GET /v1/realtime?intent=transcription HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try Data(request.utf8).withUnsafeBytes { bytes in
            guard write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else { throw failure() }
        }
        var head = Data()
        var byte: UInt8 = 0
        while !head.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)) {
            guard read(descriptor, &byte, 1) == 1 else { throw failure() }
            head.append(byte)
        }
        guard String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 101 ") else { throw POSIXError(.EPROTO) }
    }

    /// Sends all of `bytes`; false when the server has taken nothing for `stall`.
    private static func send(_ bytes: Data, _ descriptor: Int32) throws -> Bool {
        try bytes.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let wrote = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if wrote > 0 { offset += wrote; continue }
                guard errno == EAGAIN else { throw failure() }
                var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                if poll(&writable, 1, stall) == 0 { return false }
            }
            return true
        }
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// A client frame: masked, as every client frame is, of a payload under 126 bytes.
private func masked(_ opcode: UInt8, _ payload: Data, final: Bool = true) -> Data {
    let mask: [UInt8] = [1, 2, 3, 4]
    return Data([(final ? 0x80 : 0) | opcode, 0x80 | UInt8(payload.count)] + mask) + Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
}

/// `count` words, `w1` onward, each a second long.
private func timed(_ count: Int) -> Transcript {
    Transcript(words: (0..<count).map { Transcript.Word(text: " w\($0 + 1)", time: Double($0)...Double($0 + 1), confidence: 1.0) })
}

/// The deltas `body` sends through an outbox, in order.
private func deltas(_ body: (Outbox) -> Void) async -> [String] {
    let outbox = Outbox()
    body(outbox)
    outbox.close(nil)
    var sent: [String] = []
    for await case .event(.delta(_, let text)) in outbox.frames.map(\.frame) { sent.append(text) }
    return sent
}

/// The stub, saying as each transcribe starts.
private struct Starting: Transcriber {
    let stub: Stub
    let started: AsyncStream<Void>.Continuation

    func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws(TranscriptionFailure) -> Transcription {
        started.yield()
        return try await stub.transcribe(audio, expecting: vocabulary, partial: partial)
    }
}
