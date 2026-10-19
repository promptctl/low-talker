@testable import LowTalkerCore
import Testing

/// The streaming loop with a fake engine: what each pass is asked to read, when
/// passes happen, and what comes back as the transcript. The engine is a closure
/// that records the pass and returns fixed words, and a hold is driven a clip at a
/// time by waiting for a pass before feeding more, so nothing here depends on a
/// clock or a model.
@Suite struct HearingTranscribeTests {
    /// A second of margin, in samples, the same rule the engine derives its own by.
    static let margin = AudioClip.sampleCount(for: 1)

    static func speech(_ seconds: Double) -> AudioClip {
        AudioClip(samples: Array(repeating: 0.5, count: AudioClip.sampleCount(for: seconds)))
    }

    static func quiet(_ seconds: Double) -> AudioClip {
        AudioClip(samples: Array(repeating: 0.001, count: AudioClip.sampleCount(for: seconds)))
    }

    static func word(_ text: String, _ start: Double, _ end: Double) -> Transcript.Word {
        Transcript.Word(text: text, time: start...end, confidence: 0.9)
    }

    /// What every pass in these tests reads back.
    static let reading = [word(" see", 0.1, 0.4), word(" you", 0.5, 0.7)]

    /// Runs the loop over `clips`, recording every pass and every partial.
    /// `feed` is called with the audio feed and a stream of the passes so far, so a
    /// test can hold the key down a clip at a time.
    static func transcribe(
        feed: @escaping @Sendable (AsyncStream<AudioClip>.Continuation, AsyncStream<Hearing.Pass>) async -> Void
    ) async throws -> (passes: [Hearing.Pass], partials: [Partial], transcript: Transcript) {
        let (clips, clipFeed) = AsyncStream<AudioClip>.makeStream()
        let (seen, record) = AsyncStream<Hearing.Pass>.makeStream()
        let feeding = Task { await feed(clipFeed, seen) }
        var passes: [Hearing.Pass] = []
        var partials: [Partial] = []
        let transcription = try await Hearing.transcribe(clips, margin: margin, context: 3, pass: { pass in
            passes.append(pass)
            record.yield(pass)
            return reading
        }, partial: { partials.append($0) })
        record.finish()
        await feeding.value
        return (passes, partials, transcription.transcript)
    }

    /// Nothing reaching the gate is no pass at all and a refusal, not a decode of
    /// silence that comes back empty.
    @Test func aSilentHoldMakesNoPassAndIsRefused() async {
        var passes: [Hearing.Pass] = []
        let refusal = await #expect(throws: TranscriptionFailure.self) {
            (passes, _, _) = try await Self.transcribe { feed, _ in
                feed.yield(Self.quiet(2))
                feed.finish()
            }
        }
        guard case .nothingSpoken(let peak)? = refusal else { Issue.record("refused as \(String(describing: refusal))"); return }
        #expect(peak == 0.001)
        #expect(passes.isEmpty)
    }

    /// An engine that reads words into any second of quiet it is handed, as Whisper does
    /// ("Thank you."), then " see you" over the 0.4 s of speech that ends the pass.
    static func hallucinating(_ pass: Hearing.Pass) -> [Transcript.Word] {
        let longestQuiet = pass.samples.split { $0 >= Utterance.audible }.map(\.count).max() ?? 0
        let at = AudioClip.duration(for: pass.samples.count - Utterance.hangover) - 0.4
        let heardInQuiet = longestQuiet >= AudioClip.sampleCount(for: 1) ? [word(" Thank", 0, 0.2), word(" you.", 0.2, 0.4)] : []
        return heardInQuiet + [word(" see", at, at + 0.2), word(" you", at + 0.2, at + 0.4)]
    }

    /// An utterance that holds minutes of quiet, as a Realtime item does between a
    /// client's turns, is heard as only what was said in it: opening on the quiet, or with
    /// a click a second in, in clips of a second or as one clip. No pass is handed a second
    /// of the quiet, and the words are timed from the audio's first sample, not from the
    /// quiet let go (low-serve-axq.ium).
    @Test(arguments: [(click: false, clipSeconds: 1.0), (true, 1.0), (false, 400), (true, 400)])
    func quietInAnUtteranceYieldsNoWords(click: Bool, clipSeconds: Double) async throws {
        let quiet = Self.quiet(1).samples + (click ? Self.speech(0.01).samples : []) + Self.quiet(299).samples
        let audio = AudioClip(samples: quiet + Self.speech(0.4).samples)
        let (clips, feed) = AsyncStream<AudioClip>.makeStream()
        for clip in audio.chunks(of: clipSeconds) {
            feed.yield(clip)
        }
        feed.finish()
        var passes: [Hearing.Pass] = []
        let transcription = try await Hearing.transcribe(clips, margin: Self.margin, context: 3, pass: { pass in
            passes.append(pass)
            return Self.hallucinating(pass)
        }, partial: { _ in })
        #expect(!passes.isEmpty)
        #expect(transcription.transcript.text == " see you")
        #expect(abs(transcription.transcript.words[0].time.lowerBound - AudioClip.duration(for: quiet.count)) < 1e-9)
        let kept = click ? 2 * Utterance.leadIn + AudioClip.sampleCount(for: Utterance.frame) + Utterance.hangover : Utterance.leadIn
        #expect(abs(transcription.quiet.letGo - AudioClip.duration(for: quiet.count - kept)) < 1e-9)
    }

    /// Speech under a second, well under what a pass waits for during the hold,
    /// gets exactly one pass once the utterance ends, over the speech and its
    /// hangover from the start, and the words it reads are the transcript.
    @Test func aSubSecondUtteranceGetsOnePassAtItsEnd() async throws {
        let (passes, partials, transcript) = try await Self.transcribe { feed, _ in
            feed.yield(Self.speech(0.4))
            feed.finish()
        }
        #expect(passes.count == 1)
        #expect(passes[0].samples.count == AudioClip.sampleCount(for: 0.4) + Utterance.hangover)
        #expect(passes[0].arrived == AudioClip.sampleCount(for: 0.4))
        #expect(passes[0].cut == 0)
        #expect(passes[0].saying == "")
        #expect(partials.isEmpty)
        #expect(transcript.text == " see you")
    }

    /// During the hold a pass needs more than the margin of speech: speech that
    /// reaches exactly the margin with its hangover earns no pass until the end,
    /// and that pass, being the last, shows no partial.
    @Test func speechAtTheMarginEarnsNoPassUntilTheEnd() async throws {
        let (passes, partials, _) = try await Self.transcribe { feed, _ in
            feed.yield(Self.speech(0.7))
            feed.finish()
        }
        #expect(passes.count == 1)
        #expect(passes[0].samples.count == Self.margin)
        #expect(partials.isEmpty)
    }

    /// Held down, a pass runs once the speech passes the margin, the next once more
    /// speech has arrived, each over everything so far but the quiet let go, with the
    /// settled words as its prefix, and trailing quiet before key-up earns none: the
    /// pass in flight at key-up is the last.
    @Test func passesFollowTheSpeechDuringTheHoldAndStopWhenItIsHeard() async throws {
        let (passes, partials, transcript) = try await Self.transcribe { feed, seen in
            var passes = seen.makeAsyncIterator()
            feed.yield(Self.speech(0.7))
            feed.yield(Self.speech(0.1))
            _ = await passes.next()
            feed.yield(Self.quiet(1))
            feed.yield(Self.speech(0.1))
            _ = await passes.next()
            feed.yield(Self.quiet(0.5))
            feed.finish()
        }
        #expect(passes.map(\.samples.count) == [AudioClip.sampleCount(for: 0.8) + Utterance.hangover, AudioClip.sampleCount(for: 0.9) + Utterance.hangover + Utterance.leadIn + Utterance.hangover])
        #expect(passes.map(\.cut) == [0, 0])
        #expect(passes.map(\.saying) == ["", ""])
        #expect(partials.map(\.text) == [" see you", " see you"])
        #expect(partials[0].confirmed.words.isEmpty)
        #expect(partials[1].confirmed.text == " see")
        #expect(transcript.text == " see you")
    }
}
