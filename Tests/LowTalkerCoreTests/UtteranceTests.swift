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
    @Test func audioBeyondACountWaitsForTheSpeechToPassIt() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        async let heard = utterance.audio(beyond: 1_600 + Utterance.hangover)
        try await utterance.append(Self.speech(1_600))
        try await utterance.append(Self.speech(1_600))
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
    @Test func framesSpanTheClipsTheyArriveIn() async throws {
        let loud = Self.speech(1_600).samples
        let soft = (0..<10).flatMap { Array(repeating: Float($0.isMultiple(of: 2) ? 0.1 : 0.01), count: 160) }
        let whole = Utterance(judging: Verdicts.everyFrameSpeech)
        try await whole.append(AudioClip(samples: loud + soft))
        let buffered = Utterance(judging: Verdicts.everyFrameSpeech)
        for buffer in AudioClip(samples: loud + soft).chunks(of: 0.01) {
            try await buffered.append(buffer)
        }
        let (fromWhole, _, _, _) = await whole.audio(beyond: 0)
        let (fromBuffers, _, _, _) = await buffered.audio(beyond: 0)
        #expect(fromWhole.count == 3_200 + Utterance.hangover)
        #expect(fromBuffers == fromWhole)

        let partway = Utterance(judging: Verdicts.everyFrameSpeech)
        try await partway.append(Self.speech(3_199))
        try await partway.end()
        #expect(await partway.audio(beyond: 0).samples.count == 3_199 + Utterance.hangover)
    }

    /// Quiet after speech is not more speech: the audio is what was spoken plus the
    /// hangover, the hangover carrying the quiet that has actually arrived, and a
    /// wait for more does not return until the utterance ends.
    @Test func quietDoesNotGrowTheSpeech() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        try await utterance.append(Self.speech(1_600))
        try await utterance.append(Self.quiet(16_000))
        let (samples, _, ended, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == 1_600 + Utterance.hangover)
        #expect(samples.dropFirst(1_600).allSatisfy { $0 == 0.001 })
        #expect(!ended)
        async let more = utterance.audio(beyond: 1_600 + Utterance.hangover)
        try await utterance.append(Self.quiet(16_000))
        try await utterance.end()
        let (final, _, over, _) = await more
        #expect(final.count == 1_600 + Utterance.hangover)
        #expect(over)
    }

    /// Speech after quiet takes the quiet with it, but for what is past the hangover of
    /// the speech before and the lead-in of the speech after: a pause stays a pause,
    /// however long it ran, and no pass is handed more quiet than that.
    @Test func speechAfterQuietCarriesTheHangoverAndTheLeadIn() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        try await utterance.append(Self.speech(1_600))
        try await utterance.append(Self.quiet(16_000))
        try await utterance.append(Self.speech(1_600))
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
    @Test(arguments: [1.0, 61.1]) func quietBeforeSpeechIsLetGoButTheLeadIn(clipSeconds: Double) async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.004))
        let audio = AudioClip(samples: Self.quiet(60 * 16_000).samples + Self.speech(1_600).samples)
        for clip in audio.chunks(of: clipSeconds) {
            try await utterance.append(clip)
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
    @Test func theEndWakesAWaitWithWhatArrived() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        async let heard = utterance.audio(beyond: 100_000)
        try await utterance.append(Self.speech(1_605))
        try await utterance.end()
        let (samples, arrived, ended, _) = await heard
        #expect(samples.count == 1_605 + Utterance.hangover)
        #expect(arrived == 1_605)
        #expect(ended)
    }

    /// A hold with nothing said in it has no speech to hand a pass: the hangover
    /// rides on speech, so with none there is not even that.
    @Test func nothingSaidIsNoAudioAtAll() async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.004))
        try await utterance.append(Self.quiet(32_000))
        try await utterance.end()
        let (samples, _, ended, _) = await utterance.audio(beyond: 0)
        #expect(samples.isEmpty)
        #expect(ended)
    }

    /// Speech shorter than any wait is still handed over whole once the utterance
    /// ends: the speech plus its hangover, nothing withheld for being short, and the
    /// hangover that never arrived is silence that says so.
    @Test func shortSpeechIsHandedOverWholeAtTheEnd() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        async let heard = utterance.audio(beyond: 16_000)
        try await utterance.append(Self.speech(6_400))
        try await utterance.append(Self.quiet(1_600))
        try await utterance.end()
        let (samples, arrived, ended, _) = await heard
        #expect(samples.count == 6_400 + Utterance.hangover)
        #expect(arrived == 8_000)
        #expect(samples.dropFirst(arrived).allSatisfy { $0 == 0 })
        #expect(samples.prefix(6_400).allSatisfy { $0 == 0.5 })
        #expect(ended)
    }

    /// Filling from a sequence appends every clip in order and then ends.
    @Test func fillingFromASequenceAppendsEveryClipThenEnds() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        let clips = AsyncStream<AudioClip> { continuation in
            continuation.yield(Self.speech(1_000))
            continuation.yield(AudioClip(samples: Array(repeating: 0.25, count: 600)))
            continuation.finish()
        }
        try await utterance.fill(from: clips)
        let (samples, _, ended, _) = await utterance.audio(beyond: 0)
        #expect(Array(samples.prefix(1_600)) == Self.speech(1_000).samples + Array(repeating: 0.25, count: 600))
        #expect(samples.count == 1_600 + Utterance.hangover)
        #expect(ended)
    }

    /// Cancelling the fill ends the utterance: the stream's iteration returns nil on
    /// cancellation, so a waiter parked for more speech is woken with the end and
    /// never waits on a key-up that is not coming.
    @Test func cancellingTheFillEndsTheUtteranceAndWakesAWaiter() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
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

    /// A room with no speaker in it is nothing spoken, however soft the room and however it
    /// swells: before a speaker is heard only a frame the discriminator calls speech sounds, and
    /// all of it is refused as no speech.
    @Test func aRoomAloneIsNothingSpoken() async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.005))
        let clips = AsyncStream<AudioClip> { continuation in
            for frame in 0..<20 {
                continuation.yield(AudioClip(samples: Array(repeating: frame.isMultiple(of: 4) ? 0.004 : 0.002, count: 1_600)))
            }
            continuation.finish()
        }
        let refusal = await #expect(throws: TranscriptionFailure.self) {
            try await utterance.fill(from: clips)
        }
        guard case .nothingSpoken(let peak, let quiet)? = refusal else { Issue.record("refused as \(String(describing: refusal))"); return }
        #expect(peak == 0.004)
        #expect(quiet.room == 0.002 && quiet.refusedAsRoom == 0 && quiet.refusedAsNotSpeech == 2)
    }

    /// Digital silence is no sound at all: a microphone delivering zeros is nothing spoken,
    /// though with no room heard and nothing louder, every peak it is judged against is zero.
    @Test func digitalSilenceIsNothingSpoken() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        let clips = AsyncStream<AudioClip> { continuation in
            continuation.yield(AudioClip(samples: Array(repeating: 0, count: 16_000)))
            continuation.finish()
        }
        let refusal = await #expect(throws: TranscriptionFailure.self) {
            try await utterance.fill(from: clips)
        }
        guard case .nothingSpoken(let peak, let quiet)? = refusal else { Issue.record("refused as \(String(describing: refusal))"); return }
        #expect(peak == 0)
        #expect(quiet.room == nil && quiet.refusedAsRoom == 0)
    }

    /// Speech under the -40 dBFS floor is speech when it stands clear of the room: 0.008 over a
    /// room of 0.001 is heard, and so is a tenth of both, so a low input volume, a distant
    /// microphone or a whisper is cut into speech and quiet as a loud speaker is
    /// (low-reliability-z2z.3vd).
    @Test(arguments: [Float(1), 0.1]) func softSpeechStandingClearOfTheRoomIsHeard(scale: Float) async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.004 * scale))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.001 * scale, count: 16_000)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.008 * scale, count: 3_200)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.001 * scale, count: 8_000)))
        try await utterance.end()
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 3_200 + Utterance.hangover)
        #expect(timeline.quiet.range == 0.008 * scale)
    }

    /// Breathing under a speaker's level is no speech, though it stands clear of a quiet room as
    /// a whisper does: before a speaker is heard only a frame the discriminator calls speech
    /// sounds, so a press with nothing said in it is refused, not read as " Thank you."
    @Test func breathingWithNoSpeakerIsNoSpeech() async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.005))
        let clips = AsyncStream<AudioClip> { continuation in
            continuation.yield(AudioClip(samples: Array(repeating: 0.0005, count: 16_000)))
            continuation.yield(AudioClip(samples: Array(repeating: 0.004, count: 16_000)))
            continuation.finish()
        }
        let refusal = await #expect(throws: TranscriptionFailure.self) {
            try await utterance.fill(from: clips)
        }
        guard case .nothingSpoken(let peak, let quiet)? = refusal else { Issue.record("refused as \(String(describing: refusal))"); return }
        #expect(peak == 0.004)
        #expect(quiet.refusedAsRoom == 0 && quiet.refusedAsNotSpeech == 2)
    }

    /// A soft speaker who opens the press is their own room until they pause, so speech before
    /// any quiet is heard is judged by the discriminator, not the room, and kept from its first
    /// sample, however long it runs before the first pause.
    @Test func softSpeechOpeningThePressBeforeAnyQuietIsKept() async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.001))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.006, count: 6_400)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.0015, count: 1_600)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.008, count: 1_600)))
        try await utterance.end()
        let (samples, _, _, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == 9_600 + Utterance.hangover)
        #expect(samples.prefix(6_400).allSatisfy { $0 == 0.006 })
    }

    /// Soft speech that opens the press, before any of the room has been heard, is kept from its
    /// first sample once a pause in it shows the room: what came before the first frame to stand
    /// clear of the room rides with it as its lead-in.
    @Test func softSpeechOpeningThePressIsKept() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        let word = AudioClip(samples: Array(repeating: 0.008, count: 3_200))
        try await utterance.append(word)
        try await utterance.append(Self.quiet(1_600))
        try await utterance.append(word)
        try await utterance.end()
        let (samples, _, _, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == 3_200 + 1_600 + 3_200 + Utterance.hangover)
        #expect(samples.prefix(3_200).allSatisfy { $0 == 0.008 })
    }

    /// Speech is judged against the utterance's own loudest clip, not a level: a
    /// clip within the range of the loudest is speech and one under it is not, at
    /// full level and at a tenth of it alike, so a soft speaker in a quiet room is cut
    /// into speech and quiet where a loud one is.
    @Test(arguments: [Float(1), 0.1]) func speechStandsWithinRangeOfTheLoudest(scale: Float) async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.001 * scale))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.0005 * scale, count: 16_000)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.5 * scale, count: 1_600)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.04 * scale, count: 1_600)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.03 * scale, count: 1_600)))
        let (samples, _, _, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 3_200 + Utterance.hangover)
    }

    /// A click does not make the room a speaker: noise that stands no higher than the room
    /// is quiet, though it lies within range of the click, so a tap left open after a
    /// keystroke hands no pass a minute of it to read words into (low-dictation-f15).
    /// Speech that does stand above the room is speech, and the room and what it refused
    /// are on the record. A microphone that opens on digital silence has not heard the room
    /// yet, so the click's room is the one after it.
    @Test(arguments: [Float(0.002), 0]) func theRoomAfterAClickIsQuiet(opening: Float) async throws {
        let room = AudioClip(samples: (0..<16_000).map { $0.isMultiple(of: 2) ? 0.002 : -0.002 })
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.004))
        try await utterance.append(AudioClip(samples: (0..<16_000).map { $0.isMultiple(of: 2) ? opening : -opening }))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.03, count: 1_600)))
        for _ in 0..<60 { try await utterance.append(room) }
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 1_600 + Utterance.hangover)
        // Let go: all of the room but the click's lead-in and hangover, and the lead-in of
        // speech that may yet follow.
        // The room before the click is no speech, the minute after it the room; digital silence is neither.
        #expect(timeline.quiet == Quiet(letGo: AudioClip.duration(for: 61 * 16_000 - 2 * Utterance.leadIn - Utterance.hangover), room: 0.002, refusedAsRoom: 60, refusedAsNotSpeech: opening > 0 ? 1 : 0, transients: .none, range: 0.03, keptOut: nil, keptOutFrames: 0))

        try await utterance.append(AudioClip(samples: Array(repeating: 0.008, count: 1_600)))
        // The few samples the end cuts a frame short to are no tenth of a second, so no room reading.
        try await utterance.append(AudioClip(samples: Array(repeating: 0.001, count: 5)))
        try await utterance.end()
        let ended = await utterance.audio(beyond: 0)
        #expect(ended.samples.count == Utterance.leadIn + 1_600 + Utterance.hangover + Utterance.leadIn + 1_600 + Utterance.hangover)
        #expect(ended.timeline.quiet.room == 0.002)
    }

    /// A frame opening on a click as loud as speech, 0.03 s of it, and quiet for the rest.
    static let click = AudioClip(samples: Array(repeating: 0.4, count: 480) + Array(repeating: 0.001, count: 1_120))

    /// A click in a pause goes with the quiet around it (low-unfiled-50ff.7r3): no pass is handed it
    /// while speech might yet follow, and once quiet past its hangover is let go, it goes too, so
    /// the speech after the pause carries the pause and nothing else.
    @Test func aClickInAPauseGoesWithTheQuiet() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        try await utterance.append(Self.speech(1_600))
        try await utterance.append(Self.quiet(32_000))
        try await utterance.append(Self.click)
        #expect(await utterance.audio(beyond: 0).samples.count == 1_600 + Utterance.hangover)
        try await utterance.append(Self.quiet(32_000))
        try await utterance.append(Self.speech(1_600))
        try await utterance.end()
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        let pause = Utterance.hangover + Utterance.leadIn
        #expect(samples.count == 1_600 + pause + 1_600 + Utterance.hangover)
        #expect(!samples.contains(0.4))
        #expect(timeline.quiet.transients == Transients(count: 1, longest: 0.03))
    }

    /// A click a tenth of a second before speech is one burst with it, and rides with it.
    @Test func aClickJustBeforeSpeechRidesWithIt() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        try await utterance.append(Self.click)
        try await utterance.append(Self.quiet(1_600))
        try await utterance.append(Self.speech(1_600))
        try await utterance.end()
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        #expect(samples.count == 3 * 1_600 + Utterance.hangover)
        #expect(samples.prefix(480).allSatisfy { $0 == 0.4 })
        #expect(timeline.quiet.transients == .none)
    }

    /// Typing is no speech: keystrokes five a second join one burst, and however many of them
    /// there are, none sounds long enough without a break to be a syllable, so the utterance is
    /// refused with the run of them as one transient.
    @Test func typingIsNoSpeech() async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.004))
        let clips = AsyncStream<AudioClip> { continuation in
            for _ in 0..<20 {
                continuation.yield(Self.click)
                continuation.yield(Self.quiet(1_600))
            }
            continuation.finish()
        }
        let refusal = await #expect(throws: TranscriptionFailure.self) {
            try await utterance.fill(from: clips)
        }
        guard case .nothingSpoken(let peak, let quiet)? = refusal else { Issue.record("refused as \(String(describing: refusal))"); return }
        #expect(peak == 0.4)
        #expect(quiet.transients == Transients(count: 1, longest: 0.03))
    }

    /// A soft speaker after a loud click is heard: the click, refused as a transient, is no
    /// speaker to judge what follows against, so speech 24 dB under it is speech once the
    /// click has gone with the quiet.
    @Test func aSoftSpeakerAfterALoudClickIsHeard() async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.004))
        try await utterance.append(Self.click)
        try await utterance.append(Self.quiet(16_000))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.02, count: 16_000)))
        try await utterance.end()
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 16_000 + Utterance.hangover)
        #expect(!samples.contains(0.4))
        #expect(timeline.quiet.transients == Transients(count: 1, longest: 0.03))
    }

    /// A soft speaker near `audible` is heard though a syllable runs from a frame over it
    /// into one under it: the run carries the range across the frames, so the second frame is
    /// judged against the first, not against itself alone.
    @Test func aRunAtTheFloorCarriesItsRangeAcrossFrames() async throws {
        let utterance = Utterance(judging: Verdicts.speech(atOrAbove: 0.004))
        let clips = AsyncStream<AudioClip> { continuation in
            continuation.yield(Self.quiet(16_000))
            continuation.yield(AudioClip(samples: Self.quiet(960).samples + Array(repeating: 0.012, count: 640)))
            continuation.yield(AudioClip(samples: Array(repeating: 0.008, count: 1_600)))
            continuation.finish()
        }
        try await utterance.fill(from: clips)
        let (samples, _, _, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.leadIn + 640 + 1_600 + Utterance.hangover)
    }

    /// A click in the same burst as speech sets no range either: the speech is judged against
    /// its own loudest syllable, so a softer word after it, within range of the speaker but not
    /// of the click, is speech.
    @Test func aClickJoinedToSpeechSetsNoRange() async throws {
        let utterance = Utterance(judging: Verdicts.everyFrameSpeech)
        try await utterance.append(Self.click)
        try await utterance.append(Self.quiet(1_600))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.05, count: 1_600)))
        try await utterance.append(AudioClip(samples: Array(repeating: 0.02, count: 1_600)))
        try await utterance.end()
        let (samples, _, _, timeline) = await utterance.audio(beyond: 0)
        #expect(samples.count == 4 * 1_600 + Utterance.hangover)
        #expect(timeline.quiet.transients == .none)
    }
}
