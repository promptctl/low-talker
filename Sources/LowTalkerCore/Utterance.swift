import Foundation


/// The audio of one utterance as it arrives, for an engine that hears it in passes
/// while it is still being spoken. Clips are appended as they are captured; a
/// pass takes the speech so far, and the engine waits here between passes until
/// more has been spoken or the utterance has ended.
///
/// What a pass is handed is the speech: the audio from `leadIn` before the first speech
/// through `hangover` past the last clip that held speech, silence where that much has
/// not arrived yet. Quiet longer than that is let go as it arrives, however long it runs,
/// before the first speech and between speech alike: Whisper reads words into silence it
/// is handed ("Thank you."), so an utterance that opens on minutes of it, as a Realtime
/// item does between a client's turns, or holds minutes of it after a click, would
/// otherwise carry words nobody said (low-serve-axq.ium). Speech is sound that holds as a
/// syllable does (`syllable`); a click sounds too briefly, and goes with the quiet around
/// it, since a pass over a click is a pass over the quiet it sits in. What was let go is
/// kept as a `Timeline`, which times the words a pass reads in the audio appended. Trailing
/// quiet is never worth a pass, during the hold or after it: a pass over the same
/// speech and more silence reads the same words, and the encoder's cost does not
/// shrink with the tail. So the pass in flight when the key comes up is the last
/// one whenever the speaker stopped before releasing, and a hold with nothing said
/// in it costs no decode at all.
///
/// [LAW:no-ambient-temporal-coupling] The wait is on data, not on time: a pass
/// starts when the speech has grown past a sample count, whatever the clock says.
actor Utterance {
    /// The least an utterance's loudest clip can peak at and still be a speaker
    /// rather than a room: 0.01, -40 dBFS. Room noise on an M2 Max's built-in
    /// microphone peaks at -49 to -54 dBFS per tenth of a second, and the bench
    /// fixtures attenuated by 20 dB peak at -33 or louder. Whisper normalizes each
    /// window's log-mel, so it reads audio this soft as it reads loud audio; what
    /// the floor refuses is quiet, which Whisper would read words into: a hold with
    /// nothing in it, and all but the lead-in of the quiet before the first speech,
    /// however softly a word in it was said. Level is all a peak knows, so a click
    /// this loud sounds as a speaker does, and is told from one by how long it sounds
    /// (`syllable`); a clip under it sounds only when it also stands above the room
    /// (`aboveRoom`).
    static let audible: Float = 0.01
    /// A clip sounds when its peak stands within this factor of the loudest speech
    /// so far, of the run it may carry on, or of its own: 16, 24 dB, one speaker's spread from a
    /// stressed vowel to a soft consonant per tenth of a second. A ratio does not move when the level does,
    /// so a soft speaker or a low-gain microphone is cut into the same speech and
    /// quiet as a loud one. On the bench fixtures it names the same last clip of
    /// speech as the absolute -34 dBFS gate it replaces, differing on 18 of some
    /// 800 clip judgements, all mid-utterance.
    static let dynamicRange: Float = 16
    /// A clip under the audible floor sounds only when its peak also stands this
    /// far above the room's noise floor, the quietest frame of the last `roomSpan`
    /// (minimum statistics): 3, about 10 dB. The range says how soft a speaker gets
    /// below their loudest; it reaches into the room whenever the loudest is a click
    /// rather than a voice, and then a tap left open types what Whisper reads into the
    /// room's noise (" Thank you.", low-dictation-f15). Replaying the gate over the bench
    /// fixtures, at full level and 20 dB down, clean and over -51 dBFS of noise, lets
    /// go no clip the range alone called speech; at 5 the softest begins to lose some.
    static let aboveRoom: Float = 3
    /// How far back the room's noise floor is read: long enough that its quietest frame
    /// is a pause between words rather than the softest of them, and short enough that a
    /// room grown louder is soon the room again.
    static let roomSpan: TimeInterval = 3
    /// How long a burst must sound without a break to be speech: 0.06 s of `envelope`
    /// windows in a row peaking at or above the gate. A click, a keystroke or a door can peak
    /// past the floor and fill a frame as a word does, and Whisper reads " Thank you." into
    /// the 0.7 s around it (low-unfiled-50ff.7r3); what tells them apart is how long they
    /// sound unbroken, so typing, a run of keystrokes, is no more speech than one is. The
    /// clicks and keystrokes measured sound 0.02 to 0.04 s. Replaying the gate over the bench
    /// fixtures, at full level and 20 dB down, clean and over -51 dBFS of noise, hands every
    /// pass the same samples at anything from 0.05 to 0.08 s; at 0.1 s the softest loses its
    /// opening words. A run carries across frames: a syllable can sound 0.03 s in one.
    static let syllable = AudioClip.sampleCount(for: 0.06)
    /// The window a burst's sounding is measured in: a hundredth of a second.
    static let envelope = AudioClip.sampleCount(for: 0.01)
    /// Audio kept past the last clip with speech in it, so a word's soft tail rides
    /// with the word. Silence to the encoder either way, so it costs the pass nothing.
    static let hangover = AudioClip.sampleCount(for: 0.3)
    /// Audio kept before the first sample of speech, so a word's soft onset rides with
    /// the word, as its tail does with `hangover`.
    static let leadIn = AudioClip.sampleCount(for: 0.3)

    private var samples: [Float] = []
    /// Where `samples` lie in the audio appended: the quiet let go from between them.
    private var timeline = Timeline()
    /// Samples through the end of the last burst that was speech, once one has been.
    /// Each frame is judged as it fills, against the loudest and the room so far, and
    /// never again: a louder clip later may put an earlier one outside the range, but
    /// the speech only ever grows, which is what a pass waiting on it relies on.
    /// [LAW:types-are-the-program] No speech yet is its own state, not a count of
    /// zero: the hangover rides on speech, so with none there is no audio to hand a
    /// pass, and an utterance that ends in this state is refused rather than heard.
    private var spoken: Int?
    /// Frames that sound, joined while no quiet between them is let go: a word, a phrase,
    /// or a click. Its audio is kept while it lasts and handed to a pass once it is speech.
    private struct Burst {
        /// Samples through the end of its last frame that sounded.
        var through: Int
        /// Samples its `envelope` windows have sounded without a break, through its last
        /// window, the loudest of them, and the most they ever ran to.
        var run: Int
        var runPeak: Float
        var longest: Int
        /// The loudest window of a run that sounded as long as a syllable; zero until one has.
        var speechPeak: Float
        var isSpeech: Bool { longest >= Utterance.syllable }
        /// Its longest run, when that was too brief to be speech.
        var transient: Int? { isSpeech ? nil : longest }

        /// A burst nothing has sounded in yet, for a clip that sounds to open.
        static let opening = Burst(through: 0, run: 0, runPeak: 0, longest: 0, speechPeak: 0)

        /// The burst carried on through `clip`, which sounded and ends at `through`: each window
        /// peaking at or above `gate` runs on, and any other breaks the run.
        func sounding(_ clip: AudioClip, through end: Int, gate: Float) -> Burst {
            var next = self
            next.through = end
            for start in stride(from: 0, to: clip.samples.count, by: Utterance.envelope) {
                let window = clip.samples[start..<min(start + Utterance.envelope, clip.samples.count)]
                let peak = window.reduce(0) { max($0, abs($1)) }
                next.run = peak >= gate ? next.run + window.count : 0
                next.runPeak = peak >= gate ? max(next.runPeak, peak) : 0
                next.longest = max(next.longest, next.run)
                next.speechPeak = next.run >= Utterance.syllable ? max(next.speechPeak, next.runPeak) : next.speechPeak
            }
            return next
        }

        /// The burst carried on through a clip that did not sound, which breaks its run.
        var broken: Burst {
            var next = self
            (next.run, next.runPeak) = (0, 0)
            return next
        }
    }
    /// The last burst, until quiet past its hangover is let go.
    private var burst: Burst?
    /// The loudest clip peak heard: what an utterance with no speech in it is refused with.
    private var loudestHeard: Float = 0
    /// The loudest window of a run that sounded as long as a syllable: with the run a clip
    /// may carry on and its own peak, what the clip is judged against. A click's run ends
    /// short of a syllable, so a click sets no range unless nothing breaks it from the speech
    /// after it, and a soft speaker after one is heard.
    private var loudestSpeech: Float = 0
    /// The room readings of the last `roomSpan` before the frame being judged, the newest last.
    private var recent: [Float] = []
    private static let roomFrames = Int((roomSpan / frame).rounded())
    private var ended = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// The span each clip is judged in: the tenth of a second the floor and the range
    /// were measured over. [LAW:one-type-per-behavior] Frames are cut from the audio
    /// appended, not from each clip, so an upload sent as one clip, an item appended in
    /// clips of seconds, and a microphone's buffers of a hundredth of a second are cut
    /// into the same speech and quiet.
    static let frame: TimeInterval = 0.1
    private static let frameCount = AudioClip.sampleCount(for: frame)
    /// Audio appended that does not yet fill a frame: judged once it does, or as it stands
    /// when the utterance ends.
    private var unframed: [Float] = []

    func append(_ clip: AudioClip) {
        unframed += clip.samples
        let framed = unframed.count - unframed.count % Self.frameCount
        frame(Array(unframed.prefix(framed)))
        unframed.removeFirst(framed)
        wake()
    }

    private func frame(_ samples: [Float]) {
        for frame in AudioClip(samples: samples).chunks(of: Self.frame) {
            take(frame)
        }
    }

    private func take(_ clip: AudioClip) {
        let start = samples.count
        samples += clip.samples
        let peak = clip.peak
        loudestHeard = max(loudestHeard, peak)
        let loudest = max(loudestSpeech, burst?.runPeak ?? 0, peak)
        // A room reading is a whole frame that heard something: digital silence is no
        // microphone, whose own noise is never exactly zero, and a frame the end cut short
        // is no tenth of a second.
        let reading = peak > 0 && clip.samples.count == Self.frameCount ? peak : nil
        // The room: the quietest of this frame and the readings of the last `roomSpan` before it.
        let room = recent.reduce(peak, min)
        recent = Array((recent + [reading].compactMap { $0 }).suffix(Self.roomFrames))
        // The softest a sample under the floor may be and still be speech.
        let roomGate = min(Self.audible, room * Self.aboveRoom)
        // [LAW:dataflow-not-control-flow] One judgement for every clip, the loudest
        // included: it stands within range of itself, so the clip that lifts the
        // loudest past the floor sounds.
        let withinRange = loudest >= Self.audible && peak >= loudest / Self.dynamicRange
        let sounds = withinRange && peak >= roomGate
        // [LAW:nothing-unseen] What the room refused that the range alone would have kept.
        timeline.heard(reading, refusedAsRoom: withinRange && !sounds ? clip.samples.count : 0)
        let softest = max(loudest / Self.dynamicRange, roomGate)
        // Where the audio kept must resume: the lead-in before the clip's first sample
        // that sounds when the clip sounds, the lead-in before its end when it does not,
        // since the next clip may open on speech.
        let onset = sounds ? clip.samples.firstIndex { abs($0) >= softest } : nil
        let resume = start + (onset ?? clip.samples.count) - Self.leadIn
        // The burst this clip carries on: the last one, while the audio resumes within its hangover.
        let joined = burst.flatMap { resume <= $0.through + Self.hangover ? $0 : nil }
        // [LAW:dataflow-not-control-flow] Every clip lets go the quiet between the audio kept
        // and where the audio resumes, which is none while either is still arriving. What is
        // kept is the speech's hangover, or the burst's while it lasts: a burst not yet speech
        // goes whole with the quiet once it dies, so no click is left among later speech for
        // a pass to read. No pass has been handed a sample past the speech's hangover, so
        // every sample a pass has read keeps its place.
        let kept = min(joined.map { $0.through + Self.hangover } ?? speechCount, samples.count)
        let letGo = max(0, resume - kept)
        samples.removeSubrange(kept..<kept + letGo)
        timeline.letGo(letGo, at: kept)
        // [LAW:nothing-unseen] A burst that died short of speech was a transient.
        timeline.refused(transient: joined == nil ? burst?.transient : nil)
        burst = sounds ? (joined ?? .opening).sounding(clip, through: samples.count, gate: softest) : joined?.broken
        spoken = burst.flatMap { $0.isSpeech ? $0.through : nil } ?? spoken
        loudestSpeech = max(loudestSpeech, burst?.speechPeak ?? 0)
    }

    /// The key came up: nothing more arrives.
    func end() {
        frame(unframed)
        unframed = []
        // A burst still short of speech when the key comes up was a transient too.
        timeline.refused(transient: burst?.transient)
        burst = nil
        ended = true
        wake()
    }

    /// Appends every clip of `audio` as it arrives, then ends the utterance.
    ///
    /// [LAW:parse-dont-validate] An utterance with no speech in it is refused here, with its
    /// loudest peak and its quiet, the transients among it: an empty transcript would not say
    /// whether nothing was said, the audio was too soft to be a speaker, or all it held was
    /// a click. No pass is handed any of it, so the samples still kept are quiet too.
    func fill(from audio: some AsyncSequence<AudioClip, Never> & Sendable) async throws(TranscriptionFailure) {
        for await clip in audio {
            append(clip)
        }
        end()
        guard spoken != nil else { throw .nothingSpoken(peak: loudestHeard, quiet: timeline.quiet(lettingGo: samples.count)) }
    }

    /// How much audio the speech so far is worth a pass over: none until a burst is speech.
    private var speechCount: Int {
        spoken.map { $0 + Self.hangover } ?? 0
    }

    /// The speech so far, once it runs to more than `count` samples or the
    /// utterance has ended, whichever comes first, how many of its samples arrived
    /// before the silence standing in for the rest of the hangover, and where it lies
    /// in the audio appended. [LAW:one-source-of-truth] The timeline comes with the
    /// samples it places, so words are never timed by a timeline other than their audio's.
    func audio(beyond count: Int) async -> (samples: [Float], arrived: Int, ended: Bool, timeline: Timeline) {
        while speechCount <= count && !ended {
            await withCheckedContinuation { waiting.append($0) }
        }
        let arrived = min(speechCount, samples.count)
        return (Array(samples.prefix(arrived)) + Array(repeating: 0, count: speechCount - arrived), arrived, ended, timeline)
    }

    private func wake() {
        let woken = waiting
        waiting = []
        for continuation in woken {
            continuation.resume()
        }
    }
}

/// Where an utterance's samples lie in the audio appended: each stretch of quiet let go,
/// at the kept sample it was let go before. A pass reads kept samples, so the words it
/// reads are timed from the first kept sample; placed here, they are timed from the
/// audio's first sample, as a caller sent it. It also keeps the room the quiet was judged
/// against and the transients refused.
struct Timeline: Sendable {
    /// Samples let go, by the kept sample they were let go before: quiet let go at one
    /// place across many clips is one gap.
    private var gaps: [Int: Int] = [:]
    /// The quietest room reading, the least room any frame was judged against; none before one is read.
    private var room: Float?
    /// Samples within range of the loudest that stood too near the room to be speech.
    private var refusedAsRoom = 0
    /// The bursts refused as too brief to be speech.
    private var transients = Transients.none

    /// The quiet no pass is handed, and the room it was judged against.
    var quiet: Quiet { quiet(lettingGo: 0) }

    /// The quiet, with `kept` samples more that no pass will be handed.
    func quiet(lettingGo kept: Int) -> Quiet {
        Quiet(
            letGo: AudioClip.duration(for: gaps.values.reduce(0, +) + kept), room: room, refusedAsRoom: AudioClip.duration(for: refusedAsRoom),
            transients: transients
        )
    }

    /// A burst that died having sounded `longest` samples at most without a break, too few to
    /// be speech; none for one that was speech or that did not die.
    mutating func refused(transient longest: Int?) {
        transients = longest.map { Transients(count: transients.count + 1, longest: max(transients.longest, AudioClip.duration(for: $0))) } ?? transients
    }

    mutating func heard(_ reading: Float?, refusedAsRoom refused: Int) {
        room = [room, reading].compactMap { $0 }.min()
        refusedAsRoom += refused
    }

    mutating func letGo(_ count: Int, at sample: Int) {
        // Nothing let go moves nothing: a frame of speech records no gap, so the table
        // holds only the quiet that went.
        if count > 0 { gaps[sample, default: 0] += count }
    }

    /// `seconds` into the kept samples, as seconds into the audio appended. A gap at a
    /// kept sample lies before it: a word starting there starts after the gap, and a word
    /// ending there, the last before quiet let go, ended before it.
    func place(_ seconds: TimeInterval, ending: Bool = false) -> TimeInterval {
        let sample = AudioClip.sampleCount(for: seconds)
        return seconds + AudioClip.duration(for: gaps.reduce(0) { $0 + ($1.key < sample || $1.key == sample && !ending ? $1.value : 0) })
    }

    private func place(_ word: Word) -> Word {
        let start = place(word.time.lowerBound)
        // An instant at a gap starts after it, so it ends there too.
        return Word(text: word.text, time: start...max(start, place(word.time.upperBound, ending: true)), confidence: word.confidence)
    }

    /// The words, timed in the audio appended.
    func place(_ transcript: Transcript) -> Transcript {
        Transcript(words: transcript.words.map(place))
    }

    func place(_ partial: Partial) -> Partial {
        Partial(confirmed: place(partial.confirmed), tentative: place(partial.tentative), repunctuated: partial.repunctuated)
    }

    private typealias Word = Transcript.Word
}
