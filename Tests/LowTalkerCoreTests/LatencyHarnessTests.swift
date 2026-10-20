import Foundation
import LowTalkerCore
import Synchronization
import Testing

/// A bench directory built on the fly: a clip the pipeline wrote beside the text
/// it is claimed to say.
private final class BenchDirectory {
    let url: URL
    static let tone = AudioClip(samples: (0..<1_600).map { Float(sin(2 * Double.pi * 440 * Double($0) / AudioClip.sampleRate)) })

    init(under base: URL = FileManager.default.temporaryDirectory) throws {
        url = base.appending(path: "lowtalker-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// `name` may carry a folder, such as `say/greeting`.
    func add(_ name: String, text: String?, wav: Bool = true, clip: AudioClip = tone) throws {
        try FileManager.default.createDirectory(at: url.appending(path: name).deletingLastPathComponent(), withIntermediateDirectories: true)
        if wav { try clip.write(to: url.appending(path: "\(name).wav")) }
        if let text { try text.write(to: url.appending(path: "\(name).txt"), atomically: true, encoding: .utf8) }
    }
}

/// A case-sensitive volume, the only place `foo.wav` and `foo.WAV` can both exist:
/// APFS as shipped stores them as one file, so the temp directory cannot host them.
private final class CaseSensitiveVolume {
    let mountPoint: URL
    private let image: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lowtalker-cs-\(UUID().uuidString)")
        image = base.appendingPathExtension("dmg")
        mountPoint = base
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Self.hdiutil("create", "-size", "8m", "-fs", "Case-sensitive APFS", "-volname", "lowtalker-cs", "-quiet", image.path)
        try Self.hdiutil("attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet")
    }

    deinit {
        try? Self.hdiutil("detach", mountPoint.path, "-quiet")
        try? FileManager.default.removeItem(at: mountPoint)
        try? FileManager.default.removeItem(at: image)
    }

    private static func hdiutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HdiutilFailed(arguments: arguments, status: process.terminationStatus)
        }
    }

    struct HdiutilFailed: Error {
        let arguments: [String]
        let status: Int32
    }
}

@Suite struct FixtureTests {
    /// Pairs anywhere under the directory, named by their path from it.
    @Test func loadsEveryPairByName() throws {
        let bench = try BenchDirectory()
        try bench.add("zeta", text: "Last one.")
        try bench.add("say/alpha", text: "Hello, world.")
        let fixtures = try Fixture.load(directory: bench.url)
        #expect(fixtures.map(\.name) == ["say/alpha", "zeta"])
        #expect(fixtures[0].reference.words == ["hello", "world"])
        // 16-bit PCM rounds each sample, so the clip is compared by length, not value.
        #expect(fixtures[0].clip.samples.count == BenchDirectory.tone.samples.count)
    }

    /// An uppercase extension is the same file kind, not a file to skip.
    @Test func anUppercaseExtensionStillPairs() throws {
        let bench = try BenchDirectory()
        try bench.add("loud", text: "Loud.", wav: false)
        try BenchDirectory.tone.write(to: bench.url.appending(path: "loud.WAV"))
        let fixtures = try Fixture.load(directory: bench.url)
        #expect(fixtures.map(\.name) == ["loud"])
        #expect(fixtures[0].reference.words == ["loud"])
    }

    @Test func twoSpellingsOfOneClipAreRefused() throws {
        let volume = try CaseSensitiveVolume()
        try withExtendedLifetime(volume) {
            let bench = try BenchDirectory(under: volume.mountPoint)
            try bench.add("echo", text: "Echo.")
            try BenchDirectory.tone.write(to: bench.url.appending(path: "echo.WAV"))
            do {
                _ = try Fixture.load(directory: bench.url)
                Issue.record("two spellings of one clip loaded as a fixture")
            } catch FixtureError.twoOfAKind(let name, let first, let second) {
                #expect(name == "echo")
                #expect(Set([first.lastPathComponent, second.lastPathComponent]) == ["echo.wav", "echo.WAV"])
            }
        }
    }

    @Test func aClipWithoutItsWordsIsRefused() throws {
        let bench = try BenchDirectory()
        try bench.add("mute", text: nil)
        #expect(throws: FixtureError.halfAFixture(name: "mute", directory: bench.url, missing: "txt")) {
            try Fixture.load(directory: bench.url)
        }
    }

    @Test func wordsWithoutTheirClipAreRefused() throws {
        let bench = try BenchDirectory()
        try bench.add("unspoken", text: "Never recorded.", wav: false)
        #expect(throws: FixtureError.halfAFixture(name: "unspoken", directory: bench.url, missing: "wav")) {
            try Fixture.load(directory: bench.url)
        }
    }

    @Test func aReferenceWithNoWordsIsRefused() throws {
        let bench = try BenchDirectory()
        try bench.add("blank", text: " ... ")
        #expect(throws: FixtureError.referenceSaysNothing(name: "blank")) {
            try Fixture.load(directory: bench.url)
        }
    }

    /// An empty wav is a legal clip but not a fixture: there is nothing to hold.
    @Test func aClipWithNoSamplesIsRefused() throws {
        let bench = try BenchDirectory()
        try bench.add("hush", text: "Never spoken.", clip: AudioClip(samples: []))
        #expect(throws: FixtureError.clipIsEmpty(name: "hush")) {
            try Fixture.load(directory: bench.url)
        }
    }

    /// A directory the walk cannot list is its own error, not an empty set.
    @Test func aDirectoryThatCannotBeListedIsAnError() throws {
        let gone = FileManager.default.temporaryDirectory.appending(path: "lowtalker-bench-gone-\(UUID().uuidString)")
        do {
            _ = try Fixture.load(directory: gone)
            Issue.record("a missing directory loaded as a fixture set")
        } catch FixtureError.unreadable(let url, _) {
            #expect(url.standardizedFileURL.path == gone.standardizedFileURL.path)
        }
    }

    @Test func anEmptyDirectoryIsAnError() throws {
        let bench = try BenchDirectory()
        #expect(throws: FixtureError.noFixtures(directory: bench.url)) {
            try Fixture.load(directory: bench.url)
        }
    }
}

/// An engine that hears the same thing every time and says so after every clip
/// but the first, which it hears as nothing, the way a pass over leading quiet
/// reads no words; so the harness's bookkeeping can be checked without weights.
/// It remembers how many clips each utterance arrived in and what it was told
/// to expect, and says each time it has heard a clip, after its partial.
private final class FixedEar: Transcriber {
    let heard: String
    let holds = Mutex<[Int]>([])
    let told = Mutex<[Vocabulary]>([])
    let clipsHeard: AsyncStream<Void>
    private let clipHeard: AsyncStream<Void>.Continuation

    init(heard: String) {
        self.heard = heard
        (clipsHeard, clipHeard) = AsyncStream.makeStream()
    }

    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        var clips = 0
        for await _ in audio {
            clips += 1
            partial(Partial(confirmed: Transcript(words: []), tentative: Transcript(typed: clips == 1 ? "" : heard), repunctuated: 0, unread: nil))
            clipHeard.yield()
        }
        holds.withLock { $0.append(clips) }
        told.withLock { $0.append(vocabulary) }
        return Transcription(transcript: Transcript(typed: heard), quiet: .none)
    }
}

@Suite struct LatencyHarnessTests {
    static func fixture(_ name: String, says text: String, clip: AudioClip = BenchDirectory.tone) throws -> Fixture {
        try Fixture(name: name, clip: clip, reference: text)
    }

    @Test func loadsOnceAndScoresEveryFixture() async throws {
        let fixtures = [
            try Self.fixture("exact", says: "see you at noon"),
            try Self.fixture("close", says: "see me at noon soon"),
        ]
        var loads = 0
        let ear = FixedEar(heard: "See you at noon.")
        let vocabulary = Vocabulary([try Vocabulary.Term("noon")])
        let report = try await LatencyHarness.measure(fixtures, arrivals: [.batch], servings: [.idle], reruns: 2, expecting: vocabulary, on: ContinuousClock()) {
            loads += 1
            return .alone(ear)
        }
        #expect(loads == 1)
        // Every hold is told the vocabulary, reruns included.
        #expect(ear.told.withLock { $0 } == Array(repeating: vocabulary, count: 6))
        #expect(report.fixtures.map(\.name) == ["exact", "close"])
        #expect(report.fixtures.map(\.arrival) == [.batch, .batch])
        #expect(report.fixtures.map(\.wordErrorRate.errors) == [0, 2])
        #expect(report.fixtures.map(\.later.count) == [2, 2])
        #expect(report.fixtures[0].transcript.text == "See you at noon.")
        #expect(report.fixtures[0].audio == BenchDirectory.tone.duration)
        // A batch hold is the whole clip at once, every time.
        #expect(ear.holds.withLock { $0 } == [1, 1, 1, 1, 1, 1])
    }

    /// Streamed, the clip reaches the engine a microphone buffer at a time and the
    /// first text shows during the hold, on the first partial with words in it:
    /// the second buffer's, since the ear hears the first as nothing. Batched, the
    /// clip arrives whole at key-up and the first text can only follow the hold.
    ///
    /// On `TestClock`, each chunk's moment comes only once the ear has heard the one
    /// before, so the readings are the harness's timeline exactly, on any machine.
    @Test(.timeLimit(.minutes(1))) func streamedArrivalHandsOverABufferAtATime() async throws {
        let clip = AudioClip(samples: Array(repeating: 0.1, count: AudioClip.sampleCount(for: 0.35)))
        let ear = FixedEar(heard: "hi")
        let clock = TestClock()
        let arrivals: [LatencyHarness.Arrival] = [.batch, .streamed]
        let chunks = arrivals.map { clip.chunks(of: $0.chunk(of: clip)).count }
        async let measured = LatencyHarness.measure([try Self.fixture("held", says: "hi", clip: clip)], arrivals: arrivals, servings: [.idle], reruns: 0, expecting: .empty, on: clock) { .alone(ear) }
        var heard = ear.clipsHeard.makeAsyncIterator()
        for _ in 0..<chunks.reduce(0, +) {
            try await clock.advanceToNextDeadline()
            await heard.next()
        }
        let report = try await measured
        #expect(report.fixtures.map(\.arrival) == arrivals)
        #expect(chunks == [1, 4])
        #expect(ear.holds.withLock { $0 } == chunks)
        let batch = report.fixtures[0].first
        let streamed = report.fixtures[1].first
        #expect(batch.holdToFirstText == .seconds(0.35))
        #expect(streamed.holdToFirstText == .seconds(0.2))
        #expect(streamed.keyUpToTranscript == .zero)
    }

    /// While serving, every hold has three served callers around it: an upload begun
    /// before key-down, one arriving halfway through, and a stream running from before
    /// key-down to key-up. Each upload is checked against what the same upload reads with
    /// nothing else asking, which is heard once, after every hold.
    @Test func servingAsksTheServedEngineAroundEveryHold() async throws {
        let spoken = FixedEar(heard: "hi")
        let served = FixedEar(heard: "served")
        let report = try await LatencyHarness.measure([try Self.fixture("one", says: "hi")], arrivals: [.batch], servings: [.idle, .served], reruns: 1, expecting: .empty, on: ContinuousClock()) {
            LatencyHarness.Engine(dictation: spoken, served: served, turns: EngineTurns())
        }
        #expect(report.fixtures.map(\.serving) == [.idle, .served])
        #expect(report.fixtures.map(\.served) == Array(repeating: LatencyReport.Served(cancelled: 0, deferred: 0, changed: 0), count: 2))
        let streamed = AudioClip.sampleCount(for: LatencyHarness.Serving.lead + BenchDirectory.tone.duration)
        let chunks = Int((Double(streamed) / Double(AudioClip.sampleCount(for: LatencyHarness.Arrival.streamedChunk))).rounded(.up))
        #expect(served.holds.withLock { $0 }.sorted() == [1, 1, 1, 1, 1, chunks, chunks].sorted())
        #expect(spoken.holds.withLock { $0 }.count == 4)
    }

    /// Every served upload is `servedSeconds` long whatever the fixtures add up to: their
    /// audio end to end, from the first again once it runs out.
    @Test func aServedUploadIsTheFixturesCycledToItsLength() throws {
        let fixtures = [
            try Fixture(name: "a", clip: AudioClip(samples: [1, 1, 1]), reference: "x"),
            try Fixture(name: "b", clip: AudioClip(samples: [2, 2]), reference: "x"),
        ]
        let upload = LatencyHarness.Serving.upload(of: fixtures).samples
        #expect(upload.count == AudioClip.sampleCount(for: LatencyHarness.Serving.servedSeconds))
        #expect(upload.prefix(7) == [1, 1, 1, 2, 2, 1, 1])
    }

    /// The protocol's one-clip form is a batch hold.
    @Test func aClipAloneIsAOneClipUtterance() async throws {
        let ear = FixedEar(heard: "hi")
        let transcription = try await ear.transcribe(BenchDirectory.tone, expecting: .empty)
        #expect(transcription.transcript.text == "hi")
        #expect(ear.holds.withLock { $0 } == [1])
    }

    @Test func aSingleRunIsItsOwnMedian() async throws {
        let report = try await LatencyHarness.measure([try Self.fixture("one", says: "hi")], arrivals: [.batch], servings: [.idle], reruns: 0, expecting: .empty, on: ContinuousClock()) {
            .alone(FixedEar(heard: "hi"))
        }
        let result = report.fixtures[0]
        #expect(result.later.isEmpty)
        #expect(result.medianKeyUpToTranscript == result.first.keyUpToTranscript)
        #expect(result.medianHoldToFirstText == result.first.holdToFirstText)
    }

    /// An even number of runs reports the lower middle, a wait that happened.
    @Test func medianIsTheLowerMiddleOfEveryRun() {
        let result = LatencyReport.FixtureResult(
            name: "n", arrival: .batch, serving: .idle, audio: 1,
            first: LatencyReport.Run(keyUpToTranscript: .seconds(4), holdToFirstText: .seconds(9)),
            later: [
                LatencyReport.Run(keyUpToTranscript: .seconds(1), holdToFirstText: .seconds(6)),
                LatencyReport.Run(keyUpToTranscript: .seconds(3), holdToFirstText: .seconds(8)),
                LatencyReport.Run(keyUpToTranscript: .seconds(2), holdToFirstText: .seconds(7)),
            ],
            transcript: Transcript(typed: "n"),
            wordErrorRate: WordErrorRate(reference: SpokenWords("n"), hypothesis: SpokenWords("n")),
            served: LatencyReport.Served(cancelled: 0, deferred: 0, changed: 0)
        )
        #expect(result.medianKeyUpToTranscript == .seconds(2))
        #expect(result.medianHoldToFirstText == .seconds(7))
    }
}

@Suite struct AudioClipChunkTests {
    @Test func chunksCutTheClipWithTheRemainderLast() {
        let clip = AudioClip(samples: [1, 2, 3, 4, 5])
        let chunks = clip.chunks(of: 2 / AudioClip.sampleRate)
        #expect(chunks.map(\.samples) == [[1, 2], [3, 4], [5]])
    }

    @Test func anEmptyClipIsNoChunks() {
        #expect(AudioClip(samples: []).chunks(of: 1).isEmpty)
    }
}

extension LatencyHarness.Engine {
    /// One fake heard by dictation and served callers alike.
    static func alone(_ ear: any Transcriber) -> Self {
        Self(dictation: ear, served: ear, turns: EngineTurns())
    }
}
