@testable import LowTalkerCore
import Testing

@Suite struct UtteranceTests {
    /// A clip loud enough to be speech.
    static func speech(_ count: Int) -> AudioClip {
        AudioClip(samples: Array(repeating: 0.5, count: count))
    }

    /// A clip too quiet to be speech, but not digital silence.
    static func quiet(_ count: Int) -> AudioClip {
        AudioClip(samples: Array(repeating: 0.001, count: count))
    }

    /// A wait for more than a count returns only once the speech has grown past it,
    /// with everything spoken by then and the hangover after it.
    @Test func audioBeyondACountWaitsForTheSpeechToPassIt() async {
        let utterance = Utterance()
        async let heard = utterance.audio(beyond: 1_600 + Utterance.hangover)
        await utterance.append(Self.speech(1_600))
        await utterance.append(Self.speech(1_600))
        let (samples, _, ended, _) = await heard
        #expect(samples.count == 3_200 + Utterance.hangover)
        #expect(samples.prefix(3_200).allSatisfy { $0 == 0.5 })
        #expect(samples.dropFirst(3_200).allSatisfy { $0 == 0 })
        #expect(!ended)
    }

    /// Frames are cut from the audio appended, not from each clip: a microphone's buffers
    /// of a hundredth of a second are judged in tenths, as one clip would be. A soft tenth
    /// whose own peak stands within range of the loudest is speech, though half of its
    /// hundredths, judged alone, would be quiet. A frame the end leaves short is judged
    /// as it stands.
    @Test func framesSpanTheClipsTheyArriveIn() async {
        let loud = Self.speech(1_600).samples
        let soft = (0..<10).flatMap { Array(repeating: Float($0.isMultiple(of: 2) ? 0.1 : 0.01), count: 160) }
        let whole = Utterance()
        await whole.append(AudioClip(samples: loud + soft))
        let buffered = Utterance()
        for buffer in AudioClip(samples: loud + soft).chunks(of: 0.01) {
            await buffered.append(buffer)
        }
        let (fromWhole, _, _, _) = await whole.audio(beyond: 0)
        let (fromBuffers, _, _, _) = await buffered.audio(beyond: 0)
        #expect(fromWhole.count == 3_200 + Utterance.hangover)
        #expect(fromBuffers == fromWhole)

        let partway = Utterance()
        await partway.append(Self.speech(1_599))
        await partway.end()
        #expect(await partway.audio(beyond: 0).samples.count == 1_599 + Utterance.hangover)
    }

    /// Quiet after speech is not more speech: the audio is what was spoken plus the
    /// hangover, the hangover carrying the quiet that has actually arrived, and a
    /// wait for more does not return until the utterance ends.
    @Test func quietDoesNotGrowTheSpeech() async {
        let utterance = Utterance()
        await utterance.append(Self.speech(1_600))
        await utterance.append(Self.quiet(16_000))
        let (samples, _, ended, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == 1_600 + Utterance.hangover)
        #expect(samples.dropFirst(1_600).allSatisfy { $0 == 0.001 })
        #expect(!ended)
        async let more = utterance.audio(beyond: 1_600 + Utterance.hangover)
        await utterance.append(Self.quiet(16_000))
        await utterance.end()
        let (final, _, over, _) = await more
        #expect(final.count == 1_600 + Utterance.hangover)
        #expect(over)
    }

    /// Speech after quiet takes the quiet with it, but for what is past the hangover of
    /// the speech before and the lead-in of the speech after: a pause stays a pause,
    /// however long it ran, and no pass is handed more quiet than that.
    @Test func speechAfterQuietCarriesTheHangoverAndTheLeadIn() async {
        let utterance = Utterance()
        await utterance.append(Self.speech(1_600))
        await utterance.append(Self.quiet(16_000))
        await utterance.append(Self.speech(1_600))
        let (samples, _, _, timeline) = await utterance.audio(beyond: 1_600 + Utterance.hangover)
        let pause = Utterance.hangover + Utterance.leadIn
        #expect(samples.count == 1_600 + pause + 1_600 + Utterance.hangover)
        #expect(samples[1_600..<1_600 + pause].allSatisfy { $0 == 0.001 })
        #expect(samples[1_600 + pause..<3_200 + pause].allSatisfy { $0 == 0.5 })
        #expect(timeline.quiet.letGo == AudioClip.duration(for: 16_000 - pause))
    }

    /// Quiet before speech is let go but for the lead-in, however long it ran and
    /// however it was cut into clips: a minute of it and then speech, sent as one clip or
    /// in clips of a second, is handed to a pass as the lead-in and then the speech, and
    /// the timeline says how much went.
    @Test(arguments: [1.0, 61.1]) func quietBeforeSpeechIsLetGoButTheLeadIn(clipSeconds: Double) async {
        let utterance = Utterance()
        let audio = AudioClip(samples: Self.quiet(60 * 16_000).samples + Self.speech(1_600).samples)
        for clip in audio.chunks(of: clipSeconds) {
            await utterance.append(clip)
        }
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 1_600 + Utterance.hangover)
        #expect(samples.prefix(Utterance.leadIn).allSatisfy { $0 == 0.001 })
        #expect(samples[Utterance.leadIn..<Utterance.leadIn + 1_600].allSatisfy { $0 == 0.5 })
        #expect(timeline.quiet.letGo == AudioClip.duration(for: 60 * 16_000 - Utterance.leadIn))
    }

    /// The timeline places a time in the kept samples back in the audio appended: past
    /// every stretch let go before it, and none let go after it. A word ending where quiet
    /// was let go ended before it; one starting there, or an instant there, is after it.
    @Test func theTimelinePlacesKeptTimesInTheAudio() {
        var timeline = Timeline()
        timeline.letGo(16_000, at: 0)
        timeline.letGo(32_000, at: 8_000)
        #expect(timeline.place(0.25) == 1.25)
        #expect(timeline.place(0.5) == 3.5)
        #expect(timeline.place(0.5, ending: true) == 1.5)
        #expect(timeline.quiet.letGo == 3)
        let words = [Transcript.Word(text: " hello", time: 0.2...0.5, confidence: 1.0), Transcript.Word(text: " oh", time: 0.5...0.5, confidence: 1.0)]
        #expect(timeline.place(Transcript(words: words)).words.map(\.time) == [1.2...1.5, 3.5...3.5])
    }

    /// The end wakes a wait that the speech never satisfied, with what there is.
    @Test func theEndWakesAWaitWithWhatArrived() async {
        let utterance = Utterance()
        async let heard = utterance.audio(beyond: 100_000)
        await utterance.append(Self.speech(5))
        await utterance.end()
        let (samples, arrived, ended, _) = await heard
        #expect(samples.count == 5 + Utterance.hangover)
        #expect(arrived == 5)
        #expect(ended)
    }

    /// A hold with nothing said in it has no speech to hand a pass: the hangover
    /// rides on speech, so with none there is not even that.
    @Test func nothingSaidIsNoAudioAtAll() async {
        let utterance = Utterance()
        await utterance.append(Self.quiet(32_000))
        await utterance.end()
        let (samples, _, ended, _) = await utterance.audio(beyond: 0)
        #expect(samples.isEmpty)
        #expect(ended)
    }

    /// Speech shorter than any wait is still handed over whole once the utterance
    /// ends: the speech plus its hangover, nothing withheld for being short, and the
    /// hangover that never arrived is silence that says so.
    @Test func shortSpeechIsHandedOverWholeAtTheEnd() async {
        let utterance = Utterance()
        async let heard = utterance.audio(beyond: 16_000)
        await utterance.append(Self.speech(6_400))
        await utterance.append(Self.quiet(1_600))
        await utterance.end()
        let (samples, arrived, ended, _) = await heard
        #expect(samples.count == 6_400 + Utterance.hangover)
        #expect(arrived == 8_000)
        #expect(samples.dropFirst(arrived).allSatisfy { $0 == 0 })
        #expect(samples.prefix(6_400).allSatisfy { $0 == 0.5 })
        #expect(ended)
    }

    /// Filling from a sequence appends every clip in order and then ends.
    @Test func fillingFromASequenceAppendsEveryClipThenEnds() async throws {
        let utterance = Utterance()
        let clips = AsyncStream<AudioClip> { continuation in
            continuation.yield(AudioClip(samples: [1, 2]))
            continuation.yield(AudioClip(samples: [3]))
            continuation.finish()
        }
        try await utterance.fill(from: clips)
        let (samples, _, ended, _) = await utterance.audio(beyond: 0)
        #expect(Array(samples.prefix(3)) == [1, 2, 3])
        #expect(samples.count == 3 + Utterance.hangover)
        #expect(ended)
    }

    /// Cancelling the fill ends the utterance: the stream's iteration returns nil on
    /// cancellation, so a waiter parked for more speech is woken with the end and
    /// never waits on a key-up that is not coming.
    @Test func cancellingTheFillEndsTheUtteranceAndWakesAWaiter() async throws {
        let utterance = Utterance()
        // The continuation is held to the end: dropping it would finish the stream.
        let (never, feed) = AsyncStream<AudioClip>.makeStream()
        let filling = Task { try await utterance.fill(from: never) }
        async let heard = utterance.audio(beyond: 100_000)
        try await Task.sleep(for: .milliseconds(20))
        filling.cancel()
        let (samples, _, ended, _) = await heard
        #expect(ended)
        #expect(samples.isEmpty)
        feed.finish()
    }

    /// An utterance no clip of which reached the audible floor is refused with its
    /// loudest peak, not heard as nothing said.
    @Test func nothingReachingTheFloorIsRefused() async {
        let utterance = Utterance()
        let clips = AsyncStream<AudioClip> { continuation in
            continuation.yield(Self.quiet(1_600))
            continuation.yield(AudioClip(samples: [0.005, -0.008]))
            continuation.finish()
        }
        let refusal = await #expect(throws: TranscriptionFailure.self) {
            try await utterance.fill(from: clips)
        }
        guard case .nothingSpoken(let peak, _)? = refusal else { Issue.record("refused as \(String(describing: refusal))"); return }
        #expect(peak == 0.008)
    }

    /// Speech is judged against the utterance's own loudest clip, not a level: a
    /// clip within the range of the loudest is speech and one under it is not, at
    /// full level and at a tenth of it alike, so a soft speaker in a quiet room is cut
    /// into speech and quiet where a loud one is.
    @Test(arguments: [Float(1), 0.1]) func speechStandsWithinRangeOfTheLoudest(scale: Float) async {
        let utterance = Utterance()
        await utterance.append(AudioClip(samples: Array(repeating: 0.0005 * scale, count: 16_000)))
        await utterance.append(AudioClip(samples: Array(repeating: 0.5 * scale, count: 1_600)))
        await utterance.append(AudioClip(samples: Array(repeating: 0.04 * scale, count: 1_600)))
        await utterance.append(AudioClip(samples: Array(repeating: 0.03 * scale, count: 1_600)))
        let (samples, _, _, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 3_200 + Utterance.hangover)
    }

    /// A click past the floor does not make the room a speaker: noise under the floor that
    /// stands no higher than the room is quiet, though it lies within range of the click,
    /// so a tap left open after a keystroke hands no pass a minute of it to read words
    /// into (low-dictation-f15). Speech under the floor that does stand above the room is
    /// still speech, and the room and what it refused are on the record. A microphone that
    /// opens on digital silence has not heard the room yet, so the click's room is the one
    /// after it.
    @Test(arguments: [Float(0.002), 0]) func theRoomAfterAClickIsQuiet(opening: Float) async {
        let room = AudioClip(samples: (0..<16_000).map { $0.isMultiple(of: 2) ? 0.002 : -0.002 })
        let utterance = Utterance()
        await utterance.append(AudioClip(samples: (0..<16_000).map { $0.isMultiple(of: 2) ? opening : -opening }))
        await utterance.append(AudioClip(samples: Array(repeating: 0.03, count: 1_600)))
        for _ in 0..<60 { await utterance.append(room) }
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 1_600 + Utterance.hangover)
        // Let go: all of the room but the click's lead-in and hangover, and the lead-in of
        // speech that may yet follow.
        // The room before the click is under the floor, so only the minute after it was refused as room.
        #expect(timeline.quiet == Quiet(letGo: AudioClip.duration(for: 61 * 16_000 - 2 * Utterance.leadIn - Utterance.hangover), room: 0.002, refusedAsRoom: 60))

        await utterance.append(AudioClip(samples: Array(repeating: 0.008, count: 1_600)))
        // The few samples the end cuts a frame short to are no tenth of a second, so no room reading.
        await utterance.append(AudioClip(samples: Array(repeating: 0.001, count: 5)))
        await utterance.end()
        let ended = await utterance.audio(beyond: 0)
        #expect(ended.samples.count == Utterance.leadIn + 1_600 + Utterance.hangover + Utterance.leadIn + 1_600 + Utterance.hangover)
        #expect(ended.timeline.quiet.room == 0.002)
    }
}
