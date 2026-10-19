import Foundation
import Synchronization

/// Times an engine the way the app pays for it: one load, then every fixture held
/// and heard. A hold is simulated in real time: each chunk of the clip reaches the
/// engine when its audio would have been captured, the key comes up with the last
/// chunk, and the clock runs from there until the transcript is back. Delivered
/// as a batch, the whole clip is one chunk that arrives at key-up, so the engine
/// starts from nothing; streamed, it arrives a microphone buffer at a time, so the
/// engine hears during the hold and key-up finalizes the tail. Each fixture is
/// held once and then `reruns` more times, so a median shrugs off a stray pause
/// while the first hold stays apart: after warm-load at launch, the first
/// dictation of a session pays it. Every hold tells the engine the same
/// vocabulary, so a run measures what a mode's vocabulary does to hearing, on
/// the fixtures that say its terms and on the ones that do not. Every hold also
/// holds the engine as the app's presses do, and while `Serving.served` other callers
/// ask the same engine throughout, so a run measures what serving costs dictation.
///
/// [LAW:effects-at-boundaries] The clock arrives as a parameter and is read here and
/// nowhere below; scoring is `WordErrorRate`, a pure function, and the engine arrives as
/// a closure so this harness times whatever stands behind `Transcriber`. A bench run
/// hands in the wall clock; a test hands in one it moves itself, so what it asserts is
/// the harness's timeline rather than how fast the machine scheduled it.
/// [LAW:no-ambient-temporal-coupling]
public enum LatencyHarness {
    /// How a hold's audio reaches the engine.
    public enum Arrival: String, CaseIterable, Sendable {
        /// The whole clip, at key-up.
        case batch
        /// A microphone buffer at a time.
        case streamed

        /// How much audio a streamed hold hands over at once.
        ///
        /// A fixed granularity this harness chooses rather than a reading off any device,
        /// so runs stay comparable to one another and to every run already recorded. The
        /// microphone's own buffer is the device's to size - around 10 ms on this Mac's
        /// built-in input - and letting that decide would make a bench number a fact about
        /// whichever microphone was plugged in. [LAW:one-source-of-truth]
        public static let streamedChunk: TimeInterval = 0.1

        /// How much of `clip` arrives at once.
        public func chunk(of clip: AudioClip) -> TimeInterval {
            switch self {
            case .batch: clip.duration
            case .streamed: Self.streamedChunk
            }
        }
    }

    /// What else the engine is asked while dictation holds it, which is what a bench run
    /// compares: the same hold with the server idle and with it busy.
    public enum Serving: String, CaseIterable, Sendable {
        /// Nothing but the hold.
        case idle
        /// A served upload of `servedSeconds` decoding when the key goes down, another
        /// arriving halfway through the hold, and a served stream running through it.
        case served

        /// How long before key-down the served work begins, so the upload is decoding when
        /// the hold takes the engine.
        public static let lead: TimeInterval = 0.5
        /// How long each served upload is.
        public static let servedSeconds: TimeInterval = 40

        /// A served upload: `servedSeconds` of the fixtures' audio end to end, from the
        /// first again once they run out, so every fixture set asks as much of the engine.
        public static func upload(of fixtures: [Fixture]) -> AudioClip {
            let spoken = fixtures.flatMap(\.clip.samples)
            precondition(!spoken.isEmpty, "a served upload is made of the fixtures' audio, and they have none")
            return AudioClip(samples: (0..<AudioClip.sampleCount(for: servedSeconds)).map { spoken[$0 % spoken.count] })
        }

        /// The served requests around a hold of `hold` seconds, timed from key-down, their
        /// audio the upload of `fixtures`.
        func requests(from fixtures: [Fixture], hold: TimeInterval) -> [ServedRequest] {
            switch self {
            case .idle: return []
            case .served:
                let audio = Self.upload(of: fixtures)
                return [
                    ServedRequest(clip: audio, arrival: .batch, at: -Self.lead),
                    ServedRequest(clip: audio, arrival: .batch, at: hold / 2),
                    ServedRequest(clip: AudioClip(samples: Array(audio.samples.prefix(AudioClip.sampleCount(for: Self.lead + hold)))), arrival: .streamed, at: -Self.lead),
                ]
            }
        }
    }

    /// One served caller's request: its audio, how it arrives, and when, from key-down.
    struct ServedRequest {
        let clip: AudioClip
        let arrival: Arrival
        let at: TimeInterval
    }

    /// The engine as the app holds it: dictation and served callers hearing through one
    /// owner of whose decode runs next.
    public struct Engine: Sendable {
        public let dictation: any Transcriber
        public let served: any Transcriber
        public let turns: EngineTurns

        public init(dictation: any Transcriber, served: any Transcriber, turns: EngineTurns) {
            self.dictation = dictation
            self.served = served
            self.turns = turns
        }
    }

    public static func measure<C: Clock<Duration>>(
        _ fixtures: [Fixture],
        arrivals: [Arrival],
        servings: [Serving],
        reruns: UInt,
        expecting vocabulary: Vocabulary,
        on clock: C,
        load: () async throws -> Engine
    ) async throws -> LatencyReport {
        let loading = clock.now
        let engine = try await load()
        let load = loading.duration(to: clock.now)
        // Each row, and the uploads its holds' served callers read, which are judged once
        // every hold is done.
        var rows: [(uploads: [String], result: (_ changed: Int) -> LatencyReport.FixtureResult)] = []
        for fixture in fixtures {
            for arrival in arrivals {
                for serving in servings {
                    let chunks = fixture.clip.chunks(of: arrival.chunk(of: fixture.clip))
                    let requests = serving.requests(from: fixtures, hold: fixture.clip.duration)
                    let before = engine.turns.reading
                    var runs: [LatencyReport.Run] = []
                    var transcript = Transcript(words: [])
                    var uploads: [String] = []
                    for _ in 0...reruns {
                        let (run, heard, readings) = try await hold(chunks, amid: requests, with: engine, expecting: vocabulary, clock: clock)
                        runs.append(run)
                        transcript = heard
                        uploads += readings
                    }
                    let after = engine.turns.reading
                    rows.append((uploads, { changed in LatencyReport.FixtureResult(
                        name: fixture.name,
                        arrival: arrival,
                        serving: serving,
                        audio: fixture.clip.duration,
                        first: runs[0],
                        later: Array(runs.dropFirst()),
                        transcript: transcript,
                        wordErrorRate: WordErrorRate(reference: fixture.reference, hypothesis: SpokenWords(transcript.text)),
                        served: LatencyReport.Served(
                            cancelled: after.tally.cancelled - before.tally.cancelled,
                            deferred: after.tally.deferred - before.tally.deferred,
                            changed: changed
                        )
                    ) }))
                }
            }
        }
        // What the served engine makes of the upload with nothing else asking, which every
        // upload heard during a hold must match. Heard last, so the first hold after the load
        // still finds the engine as the first press after launch does.
        let servedReading = servings.contains(.served) ? try await engine.served.transcribe(Serving.upload(of: fixtures), expecting: .empty).transcript.text : ""
        return LatencyReport(load: load, fixtures: rows.map { $0.result($0.uploads.count { $0 != servedReading }) })
    }

    /// One hold amid `requests`: each served request reaches the engine when it is due, the
    /// hold takes the engine at key-down, each chunk reaches it when its audio would have been
    /// captured, the key comes up with the last, and the transcript is awaited; then the
    /// served requests are awaited too, and the uploads' readings handed back.
    private static func hold<C: Clock<Duration>>(
        _ chunks: [AudioClip],
        amid requests: [ServedRequest],
        with engine: Engine,
        expecting vocabulary: Vocabulary,
        clock: C
    ) async throws -> (LatencyReport.Run, Transcript, uploads: [String]) {
        // [LAW:no-ambient-temporal-coupling] The timeline is the requests' own: key-down
        // comes once the earliest of them has begun.
        let start = clock.now.advanced(by: .seconds(requests.reduce(0) { max($0, -$1.at) }))
        let served = requests.map { request in
            Task {
                let text = try await Self.feed(request.clip.chunks(of: request.arrival.chunk(of: request.clip)), from: start.advanced(by: .seconds(request.at)), arriving: request.arrival, clock: clock) { audio in
                    try await engine.served.transcribe(audio, expecting: .empty) { _ in }.transcript
                }.text
                return request.arrival == .batch ? text : nil
            }
        }
        // A hold that ends by throwing takes its served callers with it, so none is left
        // asking the engine behind the next hold; once they have been awaited this is moot.
        defer { served.forEach { $0.cancel() } }
        try await clock.sleep(until: start, tolerance: nil)
        let hold = engine.turns.hold()
        let firstText = Mutex<C.Instant?>(nil)
        let (audio, feed) = AsyncStream<AudioClip>.makeStream()
        async let transcription = engine.dictation.transcribe(audio, expecting: vocabulary) { partial in
            // A pass over leading quiet reads nothing; the text shown is the first
            // partial with words in it.
            let shown: C.Instant? = partial.text.isEmpty ? nil : clock.now
            firstText.withLock { $0 = $0 ?? shown }
        }
        var captured: TimeInterval = 0
        for chunk in chunks {
            captured += chunk.duration
            // [LAW:no-ambient-temporal-coupling] The sleep is the hold: audio exists
            // only once it has been spoken, and this is the one place that says when.
            try await clock.sleep(until: start.advanced(by: .seconds(captured)), tolerance: nil)
            feed.yield(chunk)
        }
        let keyUp = clock.now
        feed.finish()
        let heard: Result<Transcript, any Error>
        do { heard = .success(try await transcription.transcript) } catch { heard = .failure(error) }
        let shown = clock.now
        // Let go of whatever became of the transcript, so a failed hold leaves no served
        // request waiting on it.
        hold.release()
        let final = try heard.get()
        let first = firstText.withLock { $0 } ?? shown
        var uploads: [String] = []
        for request in served {
            if let text = try await request.value { uploads.append(text) }
        }
        return (LatencyReport.Run(keyUpToTranscript: keyUp.duration(to: shown), holdToFirstText: start.duration(to: first)), final, uploads)
    }

    /// Hands `chunks` to `hear` as a caller would: a batch whole at `start`, since an upload
    /// was recorded before it was sent, and a stream a chunk at a time as it is captured.
    private static func feed<C: Clock<Duration>>(
        _ chunks: [AudioClip],
        from start: C.Instant,
        arriving arrival: Arrival,
        clock: C,
        hear: (AsyncStream<AudioClip>) async throws -> Transcript
    ) async throws -> Transcript {
        let (audio, feed) = AsyncStream<AudioClip>.makeStream()
        async let fed: Void = {
            defer { feed.finish() }
            var captured: TimeInterval = 0
            for chunk in chunks {
                captured += arrival == .batch ? 0 : chunk.duration
                try await clock.sleep(until: start.advanced(by: .seconds(captured)), tolerance: nil)
                feed.yield(chunk)
            }
        }()
        let heard = try await hear(audio)
        try await fed
        return heard
    }
}

public struct LatencyReport: Sendable {
    /// From asking for the engine to holding one with its model resident.
    public let load: Duration
    public let fixtures: [FixtureResult]

    public struct Run: Hashable, Sendable {
        /// From the key coming up to the transcript.
        public let keyUpToTranscript: Duration
        /// From the hold beginning to the first text the engine showed: the first
        /// partial with words in it, or the transcript when there was none.
        public let holdToFirstText: Duration

        public init(keyUpToTranscript: Duration, holdToFirstText: Duration) {
            self.keyUpToTranscript = keyUpToTranscript
            self.holdToFirstText = holdToFirstText
        }
    }

    /// What the served callers around a fixture's holds went through.
    public struct Served: Equatable, Sendable {
        /// Served decodes the holds cancelled, each run again after.
        public let cancelled: Int
        /// Served decodes that asked during a hold and waited for it.
        public let deferred: Int
        /// Uploads that came back reading otherwise than the same upload heard with
        /// nothing else asking.
        public let changed: Int

        public init(cancelled: Int, deferred: Int, changed: Int) {
            self.cancelled = cancelled
            self.deferred = deferred
            self.changed = changed
        }
    }

    public struct FixtureResult: Sendable {
        public let name: String
        public let arrival: LatencyHarness.Arrival
        public let serving: LatencyHarness.Serving
        /// Seconds of speech in the clip.
        public let audio: Double
        /// The first hold is kept apart from the reruns that follow it.
        public let first: Run
        public let later: [Run]
        /// What the engine heard on the last hold.
        public let transcript: Transcript
        public let wordErrorRate: WordErrorRate
        public let served: Served

        public init(name: String, arrival: LatencyHarness.Arrival, serving: LatencyHarness.Serving, audio: Double, first: Run, later: [Run], transcript: Transcript, wordErrorRate: WordErrorRate, served: Served) {
            self.name = name
            self.arrival = arrival
            self.serving = serving
            self.audio = audio
            self.first = first
            self.later = later
            self.transcript = transcript
            self.wordErrorRate = wordErrorRate
            self.served = served
        }

        public var runs: [Run] { [first] + later }

        /// The lower middle of every hold, so an even count still reports a wait that
        /// happened.
        public var medianKeyUpToTranscript: Duration {
            runs.map(\.keyUpToTranscript).lowerMedian
        }

        public var medianHoldToFirstText: Duration {
            runs.map(\.holdToFirstText).lowerMedian
        }
    }
}

extension Array where Element == Duration {
    /// The lower middle: a value that occurred, for any count from one up.
    var lowerMedian: Duration {
        let sorted = sorted()
        return sorted[(sorted.count - 1) / 2]
    }
}
