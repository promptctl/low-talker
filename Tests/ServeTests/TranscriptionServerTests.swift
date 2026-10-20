import Identity
import Foundation
import LowTalkerCore
import Network
@testable import Serve
import Synchronization
import Testing
import TestProbes

@Suite struct TranscriptionServerTests {
    /// A second server on an address already served is refused, naming the app and the
    /// address: two servers read as that, not as a bare socket error.
    @Test func aServedAddressIsRefusedByName() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let taken = ListenAddress(port: running.server.port)
        await #expect {
            try await TranscriptionServer.listen(at: taken, engine: { .ready(Stub()) }, record: { _ in }).stop()
        } throws: { error in
            "\(error)".hasPrefix("LowTalker cannot serve on 127.0.0.1:\(running.server.port): ")
                && "\(error)".contains("Address already in use")
        }
    }

    /// The server is on loopback at the app's port unless told otherwise.
    @Test func theServerIsOnLoopbackAtTheAppsPort() {
        #expect("\(ListenAddress())" == "127.0.0.1:\(AppIdentity.serverPort)")
    }

    /// The contract, judged by the suite that judges every server (low-serve-axq.50m): its
    /// REST and Realtime checks, sent as Pipecat sends them, all pass over an engine that
    /// hears the fixture and confirms words while the audio streams. The token checks skip,
    /// since this server requires none.
    @Test func passesTheConformanceSuite() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let results = try await running.conformance()
        #expect(results.count == 13, "\(results)")
        for result in results {
            #expect(["pass", "skip"].contains(result["outcome"] as? String), "\(result)")
        }
        #expect(results.filter { $0["outcome"] as? String == "skip" }.count == 3, "\(results)")
    }

    /// Off loopback the token is required (low-serve-axq.4zr): bound to this Mac's LAN
    /// address, every check passes with it, the token checks included, which is a 401
    /// without it and, for a socket, an error event then close 3000. Each refusal is on its
    /// connection's event.
    @Test func onTheLANTheSuitePassesWithTheTokenAndIsRefusedWithout() async throws {
        let running = try await Running.startOnTheLAN(.ready(Stub()), token: "sk-lan-token")
        defer { running.server.stop() }
        #expect(running.base == "http://\(try lanAddress()):\(running.server.port.rawValue)/v1")
        let results = try await running.conformance(token: "sk-lan-token")
        #expect(results.count == 13, "\(results)")
        for result in results {
            #expect(result["outcome"] as? String == "pass", "\(result)")
        }
        // The suite's three token checks are its only refusals; every one is recorded.
        var refused: [String] = []
        for await event in running.events where event.error == "invalid_api_key" {
            refused.append("\(event.path ?? "") \(event.status ?? 0)")
            if refused.count == 3 { break }
        }
        #expect(refused.sorted() == ["/v1/audio/transcriptions 401", "/v1/audio/transcriptions 401", "/v1/realtime 101"])
    }

    /// Refused before the upload is read or the engine asked: an unknown caller learns
    /// nothing about the model, only that its key is wrong.
    @Test func withoutTheTokenARequestIs401InTheSpecShape() async throws {
        let running = try await Running.startOnTheLAN(.notResident("still loading"), token: "sk-lan-token")
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.wav", Data("not audio".utf8))], authorization: "Bearer sk-wrong")
        #expect(response.statusCode == 401)
        #expect(try error(body) as NSDictionary == [
            "message": "Incorrect API key provided.", "type": "invalid_request_error", "param": NSNull(), "code": "invalid_api_key",
        ])
        let event = try await running.nextEvent()
        #expect(event.status == 401 && event.error == "invalid_api_key" && event.bytes == nil)
    }

    /// The socket's own route answers a caller without the token the same way when what it
    /// sent is no upgrade: a 401, not the 404 or 400 that would describe the route to it.
    @Test(arguments: ["POST", "GET"])
    func withoutTheTokenTheRealtimeRouteIs401WhateverTheRequest(method: String) async throws {
        let running = try await Running.startOnTheLAN(.ready(Stub()), token: "sk-lan-token")
        defer { running.server.stop() }
        var request = URLRequest(url: URL(string: "\(running.base)/realtime?intent=transcription")!)
        request.httpMethod = method
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 401)
        #expect(try error(body)["code"] as? String == "invalid_api_key")
        let event = try await running.nextEvent()
        #expect(event.status == 401 && event.error == "invalid_api_key")
    }

    /// An mp3 is decoded as a wav is, and the engine hears all of it. The event carries
    /// the quiet the engine let go, the room it was judged against, the transients refused, and
    /// the range with what was kept out of it.
    @Test func hearsAnMP3() async throws {
        let stub = Stub(quiet: Quiet(letGo: 1.5, room: 0.25, refusedAsRoom: 0.5, transients: Transients(count: 2, longest: 0.03), range: 0.5, keptOut: 0.75, keptOutFrames: 3))
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("gpt-transcribe".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3"))])
        #expect(response.statusCode == 200)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: AnyHashable] == [
            "text": "Hello world, this is LowTalker.", "usage": ["type": "duration", "seconds": 3] as [String: AnyHashable],
        ])
        let seconds = try #require(stub.heard.withLock { $0.first?.seconds })
        #expect(seconds > 2.2 && seconds < 2.6)
        let event = try await running.nextEvent()
        #expect(event.status == 200 && event.words == 5 && event.model == "gpt-transcribe" && event.error == nil)
        #expect(event.quietSeconds == 1.5 && event.nothingSpokenPeak == nil)
        #expect(event.roomPeak == 0.25 && event.refusedAsRoomSeconds == 0.5)
        #expect(event.transients == 2 && event.longestTransientSeconds == 0.03)
        #expect(event.rangePeak == 0.5 && event.keptOutPeak == 0.75 && event.keptOutFrames == 3)
    }

    /// An upload no sample of which reached the audible floor, a push-to-talk hold where
    /// nothing was said, is answered as OpenAI answers one: 200 with empty text, in either
    /// format, never 500 (low-serve-7t8). Its event carries the peak that decided it.
    @Test(arguments: [
        ("json", Data(#"{"text":"","usage":{"seconds":3,"type":"duration"}}"#.utf8)),
        ("text", Data("\n".utf8)),
        ("verbose_json", Data(#"{"duration":2.5,"language":"english","segments":[],"task":"transcribe","text":"","usage":{"seconds":3,"type":"duration"}}"#.utf8)),
    ])
    func anUploadWithNothingSpokenIsEmptyText(format: String, answer: Data) async throws {
        let running = try await Running.start(.ready(Stub(quiet: Quiet(letGo: 2.5, room: 0.002, refusedAsRoom: 0, transients: .none, range: nil, keptOut: nil, keptOutFrames: 0))))
        defer { running.server.stop() }
        // 0.0025, about -52 dBFS: a quiet room's hold, under the -40 dBFS floor.
        let (response, body) = try await running.post([
            ("model", nil, Data("m".utf8)), ("response_format", nil, Data(format.utf8)), ("file", "audio.wav", wav(seconds: 2.5, peak: 0.0025)),
        ])
        #expect(response.statusCode == 200)
        #expect(body == answer, "\(String(decoding: body, as: UTF8.self))")
        let event = try await running.nextEvent()
        #expect(event.status == 200 && event.error == nil && event.words == 0)
        // The quiet the engine refused it with, the room it heard included.
        #expect(event.quietSeconds == 2.5 && event.roomPeak == Double(Float(0.002)))
        #expect(event.rangePeak == nil && event.keptOutPeak == nil && event.keptOutFrames == 0)
        let peak = try #require(event.nothingSpokenPeak)
        // Within a 16-bit step of the peak written.
        #expect(abs(peak - 0.0025) < 0.0001)
        #expect(event.avgLogprob == nil && event.compressionRatio == nil)
    }

    /// verbose_json serves what the engine was sure of where an OpenAI client reads it
    /// (low-serve-4a9): one segment spanning the words, its avg_logprob the mean of their log
    /// probabilities and its compression_ratio as Whisper measures it (zlib's, as Python's
    /// zlib.compress gives it). The event carries the same scores.
    @Test func verboseJSONServesTheSegmentsAverageLogProbability() async throws {
        let stub = Stub(.success(Transcript(words: [
            Transcript.Word(text: " Okay,", time: 0.25...0.5, confidence: 0.5),
            Transcript.Word(text: " now.", time: 0.5...0.75, confidence: 0.25),
        ])))
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, body) = try await running.post([
            ("model", nil, Data("m".utf8)), ("response_format", nil, Data("verbose_json".utf8)), ("file", "audio.wav", wav(seconds: 1, peak: 0.5)),
        ])
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "content-type") == "application/json")
        let answer = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let segments = try #require(answer["segments"] as? [[String: Any]])
        let score = (log(0.5) + log(0.25)) / 2
        #expect(segments.count == 1)
        #expect(try abs(#require(segments.first?["avg_logprob"] as? Double) - score) < 1e-12)
        #expect(segments.first?.filter { $0.key != "avg_logprob" } as NSDictionary? == [
            "id": 0, "start": 0.25, "end": 0.75, "text": "Okay, now.", "compression_ratio": 10.0 / 18,
        ])
        #expect(answer.filter { $0.key != "segments" } as NSDictionary == [
            "task": "transcribe", "language": "english", "duration": 1, "text": "Okay, now.", "usage": ["type": "duration", "seconds": 1],
        ])
        let event = try await running.nextEvent()
        #expect(event.format == "verbose_json")
        #expect(try abs(#require(event.avgLogprob) - score) < 1e-12)
        #expect(event.compressionRatio == 10.0 / 18)
    }

    /// A request that asks while the speaker holds the engine waits for the hold, and its
    /// event says so.
    @Test func aRequestThatWaitedForAHoldSaysSoInItsEvent() async throws {
        let turns = EngineTurns()
        let running = try await Running.start(.ready(Turning(turns: turns)))
        defer { running.server.stop() }
        let hold = turns.hold()
        async let answered = running.post([("model", nil, Data("m".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3"))])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { turns.reading.waiting == 1 })
        #expect(hold.release().waiting == 1)
        #expect(try await answered.0.statusCode == 200)
        #expect(try await running.nextEvent().turns == EngineTurns.Tally(deferred: 1))
    }

    /// Uploads past the limit at once are refused with the 429 Pipecat retries, while the
    /// one taken in waits out the hold and is answered; each event says how many were in.
    @Test func anUploadPastTheLimitIs429WhileTheOneTakenInIsAnswered() async throws {
        let turns = EngineTurns()
        let running = try await Running.start(.ready(Turning(turns: turns)), limits: ServedLimits(uploads: 1, sockets: 1, audio: 60))
        defer { running.server.stop() }
        let hold = turns.hold()
        let upload = [("model", nil, Data("m".utf8)), ("file", "audio.mp3", try fixture("hello-16k-mono.mp3"))] as [(name: String, filename: String?, value: Data)]
        async let answered = running.post(upload)
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { turns.reading.waiting == 1 })
        let (refused, body) = try await running.post(upload)
        #expect(refused.statusCode == 429)
        #expect(try error(body)["code"] as? String == "rate_limit_exceeded")
        let refusal = try await running.nextEvent()
        #expect(refusal.status == 429 && refusal.uploads == 1 && refusal.bytes == nil)
        hold.release()
        #expect(try await answered.0.statusCode == 200)
        let taken = try await running.nextEvent()
        #expect(taken.status == 200 && taken.uploads == 1)
        // The refused upload's place was never taken, and the answered one's is given back.
        #expect(try await running.post(upload).0.statusCode == 200)
    }

    /// An upload holding more audio than the limit is refused by its length, before any of
    /// it is decoded or the engine hears it.
    @Test func anUploadLongerThanTheLimitIs400() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub), limits: ServedLimits(uploads: 4, sockets: 1, audio: 1))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3"))])
        #expect(response.statusCode == 400)
        #expect(try error(body)["code"] as? String == "audio_too_long")
        #expect(try error(body)["param"] as? String == "file")
        #expect(stub.heard.withLock { $0.isEmpty })
        let event = try await running.nextEvent()
        // The length its header gave, which is what refused it.
        let claimed = try #require(event.audioSeconds)
        #expect(event.error == "audio_too_long" && abs(claimed - 2.2585) < 0.01)
    }

    /// A header whose rate gives its audio no length (0 Hz, which AVAudioConverter takes) is
    /// a 400, not a length the server computes with.
    @Test func anUploadWhoseRateGivesNoLengthIs400() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.caf", fixture("zero-rate.caf"))])
        #expect(response.statusCode == 400)
        #expect(try error(body)["code"] as? String == "invalid_audio")
        #expect(stub.heard.withLock { $0.isEmpty })
    }

    /// The prompt is the vocabulary a dictation mode would give: one term, as written.
    @Test func promptIsTheVocabulary() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, _) = try await running.post([
            ("model", nil, Data("m".utf8)), ("prompt", nil, Data(" LowTalker ".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 200)
        #expect(stub.heard.withLock { $0.first?.vocabulary } == Vocabulary([try Vocabulary.Term("LowTalker")]))
        #expect(try await running.nextEvent().vocabularyTerms == 1)
    }

    /// A prompt with no word in it is ordinary speech: no vocabulary, and no refusal.
    @Test func aWordlessPromptIsNoVocabulary() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, _) = try await running.post([
            ("model", nil, Data("m".utf8)), ("prompt", nil, Data(" ... ".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 200)
        #expect(stub.heard.withLock { $0.first?.vocabulary } == Vocabulary([]))
    }

    /// No words heard in real audio is an empty transcript, not a failure.
    @Test func realAudioWithNoWordsIsAnEmptyTranscript() async throws {
        let running = try await Running.start(.ready(Stub(.success(Transcript(words: [])))))
        defer { running.server.stop() }
        let (response, body) = try await running.post([
            ("model", nil, Data("m".utf8)), ("response_format", nil, Data("text".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "\n")
    }

    /// Refused before the upload is read: a file that is not audio still hears 503.
    @Test func aRequestBeforeTheModelIsResidentIs503() async throws {
        let running = try await Running.start(.notResident("still loading"))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.wav", Data("not audio".utf8))])
        #expect(response.statusCode == 503)
        #expect(try error(body)["code"] as? String == "model_not_ready")
        #expect(try (error(body)["message"] as? String)?.contains("still loading") == true)
        let event = try await running.nextEvent()
        #expect(event.error == "model_not_ready" && event.audioSeconds == nil)
    }

    /// A model that could not be loaded is a 500, not the 503 that tells a client to wait.
    @Test func aModelThatFailedToLoadIs500() async throws {
        let running = try await Running.start(.failed("the model failed to load: no weights"))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.wav", Data("not audio".utf8))])
        #expect(response.statusCode == 500)
        #expect(try error(body)["code"] as? String == "transcription_failed")
        #expect(try (error(body)["message"] as? String)?.contains("no weights") == true)
        let event = try await running.nextEvent()
        #expect(event.error == "transcription_failed")
    }

    /// A prompt the engine cannot take is the client's to fix, so it is a 400 naming it.
    @Test func aPromptTheEngineRefusesIs400() async throws {
        let running = try await Running.start(.ready(Stub(.failure(.vocabulary(.tooLong(tokens: 300, limit: 224))))))
        defer { running.server.stop() }
        let (response, body) = try await running.post([
            ("model", nil, Data("m".utf8)), ("prompt", nil, Data("a long paragraph".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 400)
        #expect(try error(body)["param"] as? String == "prompt")
        #expect(try error(body)["type"] as? String == "invalid_request_error")
    }

    /// A refusal made before the body is read still reaches a client that is sending one
    /// larger than the socket holds, and the drain is recorded. How much of the body the
    /// client goes on sending once it hears the refusal is the client's choice.
    @Test func aRefusedBodyIsDrainedSoTheClientHearsTheRefusal() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let oversize = TranscriptionServer.bodyLimit + 1024 * 1024
        let (response, body) = try await running.post(Data(count: oversize))
        #expect(response.statusCode == 413)
        #expect(try error(body)["code"] as? String == "request_too_large")
        let event = try await running.nextEvent()
        #expect(event.status == 413 && event.unread != nil && event.lost == nil)
    }

    /// A client that closes before its request is whole is recorded as lost, unanswered.
    @Test func aConnectionClosedMidRequestIsLost() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let connection = NWConnection(host: .ipv4(.loopback), port: running.server.port, using: .tcp)
        connection.start(queue: DispatchQueue(label: "test.client"))
        connection.send(content: Data("POST /v1/audio/transcriptions HTTP/1.1\r\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        defer { connection.cancel() }
        let event = try await running.nextEvent()
        #expect(event.status == nil && event.lost != nil)
    }

    /// A client that expects to be told to go on hears 100 Continue before it sends a byte
    /// of body, then the answer.
    @Test func aClientExpectingContinueIsToldToSendTheBody() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let connection = NWConnection(host: .ipv4(.loopback), port: running.server.port, using: .tcp)
        connection.start(queue: DispatchQueue(label: "test.client"))
        defer { connection.cancel() }
        let body = Data("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n--b--\r\n".utf8)
        let head = "POST /v1/audio/transcriptions HTTP/1.1\r\ncontent-type: multipart/form-data; boundary=b\r\ncontent-length: \(body.count)\r\nexpect: 100-continue\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        #expect(try await connection.received() == "HTTP/1.1 100 Continue\r\n\r\n")
        connection.send(content: body, completion: .idempotent)
        #expect(try await connection.received().hasPrefix("HTTP/1.1 400 "))
    }

    @Test func stoppingEndsTheServer() async throws {
        let running = try await Running.start(.ready(Stub()))
        running.server.stop()
        try await running.server.finished()
    }

    @Test func anEngineFailureIs500WithTheReason() async throws {
        let running = try await Running.start(.ready(Stub(.failure(.engine(StubFailure())))))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3"))])
        #expect(response.statusCode == 500)
        #expect(try (error(body)["message"] as? String)?.contains("the stub engine was told to fail") == true)
    }

    /// Refusals the conformance suite does not send, each in OpenAI's error shape and each
    /// naming what it refused.
    @Test(arguments: [
        ([("file", "audio.wav", "RIFF")], 400, "missing_required_parameter", "model"),
        ([("model", nil, "m"), ("model", nil, "m"), ("file", "audio.wav", "RIFF")], 400, "repeated_parameter", "model"),
        ([("model", nil, "m"), ("stream", nil, "true"), ("file", "audio.wav", "RIFF")], 400, "unsupported_parameter", "stream"),
        ([("model", nil, "m"), ("file", "audio.wav", "not audio at all")], 400, "invalid_audio", "file"),
        ([("model", nil, "m"), ("language", nil, "fr"), ("file", "audio.wav", "RIFF")], 400, "unsupported_value", "language"),
    ] as [([(String, String?, String)], Int, String, String)])
    func refusesAndSaysWhat(fields: [(String, String?, String)], status: Int, code: String, param: String) async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let (response, body) = try await running.post(fields.map { ($0.0, $0.1, Data($0.2.utf8)) })
        #expect(response.statusCode == status)
        #expect(try error(body)["code"] as? String == code)
        #expect(try error(body)["param"] as? String == param)
        // The server's own temporary files are not the client's business.
        #expect(try (error(body)["message"] as? String)?.contains("lowtalker-upload-") == false)
    }

    @Test func anotherPathIs404() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let (response, body) = try await running.post([], path: "audio/translations")
        #expect(response.statusCode == 404)
        #expect(try error(body)["code"] as? String == "unknown_url")
        let event = try await running.nextEvent()
        #expect(event.path == "/v1/audio/translations" && event.status == 404 && event.bytes == nil)
    }
}

@Suite struct FormFieldTests {
    @Test func readsFieldsAroundAPreambleUnderAQuotedBoundary() throws {
        let body = Data("preamble\r\n--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n\r\nx\r\n--b--\r\n".utf8)
        #expect(try FormField.parse(body, contentType: "multipart/form-data; boundary=\"b\"") == [
            FormField(name: "model", filename: nil, value: Data("m".utf8)),
            FormField(name: "file", filename: "a.wav", value: Data("\r\nx".utf8)),
        ])
    }

    /// Two lengths for one body are no length: the request is refused, not read by one.
    @Test func twoContentLengthsAreMalformed() throws {
        let head = try RequestHead.parse(Data("POST / HTTP/1.1\r\ncontent-length: 5\r\nContent-Length: 6".utf8))
        #expect(throws: APIError.malformed("content-length \"5, 6\" is not a byte count")) {
            try head.bodyLength(limit: 100)
        }
    }

    @Test func aSemicolonInsideAQuotedFilenameIsPartOfIt() {
        #expect(FormField.parameter("filename", in: "form-data; name=\"file\"; filename=\"take;1.mp3\"") == "take;1.mp3")
    }

    @Test func aBodyWithNoClosingBoundaryIsMalformed() {
        let body = Data("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n".utf8)
        #expect(throws: APIError.malformed("the multipart body has no closing boundary")) {
            try FormField.parse(body, contentType: "multipart/form-data; boundary=b")
        }
    }
}

extension NWConnection {
    /// The next bytes the server sent, as text.
    fileprivate func received() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self)) }
            }
        }
    }
}
