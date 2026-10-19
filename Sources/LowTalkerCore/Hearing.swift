/// The bookkeeping of an utterance decoded in passes while it is still being
/// spoken: which words are settled, what the latest pass read after them, and
/// what the next pass starts from.
///
/// Every pass reads from the cut to the end of the audio so far. It starts a few
/// confirmed words back, the prefix, and is told those words in advance, so the
/// decoder continues a sentence it has heard rather than starting cold at a word
/// boundary; the words it reads for the prefix are dropped. A word settles when
/// two passes in a row read it the same (the local-agreement rule of
/// whisper_streaming, Macháček et al. 2023) and it ended at least `margin` before
/// the later pass's end, so that the next pass, starting no later than that word,
/// still spans more than `margin` of speech. The engine decodes no window shorter
/// than its end clip; the transcriber pads an utterance shorter than that out to
/// the floor with silence, and this margin keeps every later pass over speech alone.
///
/// A settled word's trailing punctuation is still the next pass's to revise, since
/// that pass is told the prefix without it (`saying`). So the last settled word is
/// final only once a word settles after it: until then the partial shows it as
/// tentative, and nothing that reads the confirmed words as they come takes it.
///
/// [LAW:effects-at-boundaries] A value with no engine and no clock: words come in
/// with the sample count they were read through, and the engine reads out where
/// to start next and what to say first. The pass itself is the engine's.
struct Hearing: Equatable {
    /// Samples a settled word must end before a pass's end.
    let margin: Int
    /// How many confirmed words a pass starts from.
    let context: Int
    /// Words two passes agreed on, read again only as a pass's prefix. No later pass
    /// changes them, but for the last one's trailing punctuation.
    private(set) var confirmed: [Transcript.Word] = []
    /// The latest pass's reading of everything after the confirmed words.
    private(set) var tentative: [Transcript.Word] = []
    /// Samples the latest pass read through.
    private(set) var heard = 0
    /// Passes that changed the last confirmed word's punctuation.
    private(set) var repunctuated = 0

    init(margin: Int, context: Int) {
        precondition(margin >= 0, "a margin reaches back from a pass's end, not forward")
        precondition(context >= 0, "a pass starts from some confirmed words, or none")
        self.margin = margin
        self.context = context
    }

    /// The confirmed words the next pass starts from and is told in advance.
    var prefix: [Transcript.Word] {
        Array(confirmed.suffix(context))
    }

    /// What the next pass is told to say first: the prefix's text without its final
    /// punctuation. Told a sentence-final period and then hearing a pause, Whisper
    /// closes the transcript there and every word after the pause is lost; told the
    /// words alone, it reads the punctuation back itself and goes on. A prefix word
    /// is matched the same way, so it is dropped whether it comes back punctuated
    /// or not.
    var saying: String {
        Self.unpunctuated(prefix.map(\.text).joined())
    }

    private static func unpunctuated(_ text: String) -> String {
        String(text.reversed().drop(while: \.isPunctuation).reversed())
    }

    /// [LAW:one-source-of-truth] The one rule for two passes reading the same word:
    /// trailing punctuation is the later pass's to revise, in a prefix or in a
    /// tentative word alike.
    private static func sameWord(_ earlier: Transcript.Word, _ later: Transcript.Word) -> Bool {
        unpunctuated(earlier.text) == unpunctuated(later.text)
    }

    /// Where the next pass starts: the first prefix word's start, so the pass hears
    /// the words it is told. [LAW:one-source-of-truth] Derived from the confirmed
    /// words, so it moves forward exactly as they settle and never back.
    var cut: Int {
        prefix.first.map { AudioClip.sampleCount(for: $0.time.lowerBound) } ?? 0
    }

    /// The sample count the speech must exceed before a pass is worth starting while
    /// the utterance is still being spoken: new audio since the last pass, and more
    /// than `margin` past the cut, so the first pass reads a second of speech rather
    /// than a fragment padded out with silence. Once the utterance has ended, any
    /// speech past `heard` is worth the last pass, however short.
    var passable: Int {
        max(heard, cut + margin)
    }

    /// Takes in a pass that read `words`, from the cut through `end` samples. The
    /// words it read for its prefix come first and are dropped; a prefix read
    /// differently stays, visible, rather than vanishing. A prefix read the same
    /// punctuates the last confirmed word as this pass does.
    mutating func hear(_ words: [Transcript.Word], through end: Int) {
        let reread = zip(prefix, words).prefix { Self.sameWord($0, $1) }.count
        if reread == prefix.count, let last = confirmed.last, let reading = words.prefix(reread).last {
            // The settled reading's time stays: `cut` derives from confirmed times and never moves back.
            repunctuated += reading.text == last.text ? 0 : 1
            confirmed[confirmed.count - 1] = Transcript.Word(text: reading.text, time: last.time, confidence: last.confidence)
        }
        let fresh = words.dropFirst(reread)
        let agreed = zip(tentative, fresh).prefix { Self.sameWord($0, $1) }.count
        let settled = fresh.prefix(agreed).prefix { AudioClip.sampleCount(for: $0.time.upperBound) <= end - margin }
        confirmed += settled
        tentative = Array(fresh.dropFirst(settled.count))
        heard = end
    }

    /// [LAW:types-are-the-program] The partial's confirmed words are the ones whose text
    /// is final, so a reader can take them as they come: every confirmed word but the
    /// last, whose punctuation the next pass may still revise.
    var partial: Partial {
        Partial(confirmed: Transcript(words: confirmed.dropLast()), tentative: Transcript(words: confirmed.suffix(1) + tentative), repunctuated: repunctuated)
    }

    /// The utterance as heard so far, which is the transcript once no more audio
    /// comes: the last pass's reading is final when nothing follows it.
    var transcript: Transcript {
        Transcript(words: confirmed + tentative)
    }
}

extension Hearing {
    /// What one pass is asked to read: the speech so far, how much of it arrived before
    /// the silence run out past it, where in it to start, and the confirmed words to say
    /// first.
    struct Pass: Equatable, Sendable {
        let samples: [Float]
        let arrived: Int
        let cut: Int
        let saying: String
    }

    /// Hears an utterance out as it arrives: fills it from `audio`, and runs `pass`
    /// over the speech so far whenever the engine is free and speech worth a pass has
    /// arrived, feeding the words back in and telling `partial` what is heard so far.
    /// The last pass's reading is the transcript, told with the quiet the utterance let
    /// go. Engine-agnostic: `pass` is the
    /// engine, `margin` the span it decodes no window under, and `context` how many
    /// confirmed words it is told to say first.
    ///
    /// [LAW:dataflow-not-control-flow] The one branch is the utterance's own state:
    /// speech to hear, or nothing more. A pass over what is there is the same pass
    /// whether the key is still down or just came up, and the last pass's reading is
    /// the transcript once no speech follows it. During the hold a pass waits for
    /// speech worth one; once the utterance has ended, whatever speech no pass has
    /// heard gets the last pass, however short, and the engine pads it out to its
    /// floor. So a tap-to-toggle "yes" is heard, not decoded as nothing, and a hold
    /// with nothing said in it is still no pass at all.
    static func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        margin: Int,
        context: Int,
        pass: (Pass) async throws(TranscriptionFailure) -> [Transcript.Word],
        partial: (Partial) -> Void
    ) async throws(TranscriptionFailure) -> Transcription {
        let utterance = Utterance()
        // A value, because an `async let` throws untyped.
        async let fed = Result { () async throws(TranscriptionFailure) in try await utterance.fill(from: audio) }
        var hearing = Hearing(margin: margin, context: context)
        var heard = await utterance.audio(beyond: hearing.passable)
        while heard.samples.count > hearing.heard {
            let words = try await pass(Pass(samples: heard.samples, arrived: heard.arrived, cut: hearing.cut, saying: hearing.saying))
            hearing.hear(words, through: heard.samples.count)
            if heard.ended { break }
            partial(heard.timeline.place(hearing.partial))
            heard = await utterance.audio(beyond: hearing.passable)
        }
        try await fed.get()
        // Timed from the audio's first sample, not from the quiet the utterance let go.
        return Transcription(transcript: heard.timeline.place(hearing.transcript), quiet: heard.timeline.quiet)
    }
}
