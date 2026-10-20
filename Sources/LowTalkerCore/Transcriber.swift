import Foundation

/// Turns an utterance into a Transcription. The engine behind it is a config choice:
/// WhisperKit first, with Parakeet and Apple's SpeechAnalyzer behind the same seam.
///
/// [LAW:no-ambient-temporal-coupling] A Transcriber is ready the moment it exists.
/// Every engine loads its model in its initializer, so there is no unloaded
/// transcriber to call too early and no warm-up step a caller can forget. The app
/// holds "still loading" as its own state until the initializer returns; here, a
/// value in hand is the proof the model is resident.
public protocol Transcriber: Sendable {
    /// Hears an utterance while it is being spoken. `audio` is the utterance's clips
    /// in the order they were captured, ending when the key comes up; the engine
    /// decodes as they arrive and tells `partial` what it has heard so far, so a HUD
    /// can show text before the key is released. The transcription returned once
    /// `audio` ends is the final one: its transcript replaces every partial. `vocabulary` is
    /// what the speaker is expected to say beyond ordinary speech, told to the
    /// engine before it hears anything, so the mode that started the utterance
    /// biases every reading of it.
    ///
    /// [LAW:types-are-the-program] One final and any number of partials: the final
    /// is the return value, so a caller cannot miss it or receive two.
    func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws(TranscriptionFailure) -> Transcription
}

/// An utterance as the engine heard it: the words it read, and the account of the quiet
/// around them that no pass was handed.
///
/// [LAW:types-are-the-program] The quiet is the utterance's, not its words': a slice of the
/// words, a partial, or a run handed to the cursor is a Transcript, and has no quiet to lose.
public struct Transcription: Sendable {
    public let transcript: Transcript
    public let quiet: Quiet

    public init(transcript: Transcript, quiet: Quiet) {
        self.transcript = transcript
        self.quiet = quiet
    }
}

/// What the speech gate made of an utterance's quiet: how much it let go, the room and the
/// range it judged it against, what the room, the discriminator and the transients refused,
/// and what was kept out of the range.
public struct Quiet: Hashable, Sendable {
    /// Seconds no pass was handed, before the speech and between it: heard as nothing,
    /// while the words are still timed in the audio as it was sent.
    public let letGo: TimeInterval
    /// The peak of the quietest tenth of a second heard, digital silence aside: the least
    /// room the quiet was judged against. None when no room was heard.
    public let room: Float?
    /// Seconds within range of the loudest that stood too near the room to be speech.
    public let refusedAsRoom: TimeInterval
    /// Seconds within range of the loudest and clear of the room, before any speaker was heard,
    /// that the discriminator called something other than speech: breathing or a fan under a
    /// speaker's level, which the room alone would have let through as it does a whisper.
    public let refusedAsNotSpeech: TimeInterval
    public let transients: Transients
    /// The peak of the loudest syllable in frames the discriminator called speech: the range
    /// the speech was judged against. None when no such syllable was heard.
    public let range: Float?
    /// The loudest sound that stood above the range when it was heard and was kept out of it,
    /// the discriminator having called it something other than speech, and how many frames
    /// were. A cough before a soft speaker, or a loudest syllable the discriminator missed: this
    /// says what the gate did, not which. None, and zero frames, when nothing was.
    public let keptOut: Float?
    public let keptOutFrames: Int

    /// Nothing let go, no room heard, nothing refused and no range.
    public static let none = Quiet(letGo: 0, room: nil, refusedAsRoom: 0, refusedAsNotSpeech: 0, transients: .none, range: nil, keptOut: nil, keptOutFrames: 0)

    public init(
        letGo: TimeInterval, room: Float?, refusedAsRoom: TimeInterval, refusedAsNotSpeech: TimeInterval,
        transients: Transients, range: Float?, keptOut: Float?, keptOutFrames: Int
    ) {
        self.letGo = letGo
        self.room = room
        self.refusedAsRoom = refusedAsRoom
        self.refusedAsNotSpeech = refusedAsNotSpeech
        self.transients = transients
        self.range = range
        self.keptOut = keptOut
        self.keptOutFrames = keptOutFrames
    }
}

/// The bursts of sound the gate refused as too brief to be speech, a click, a door or a run of
/// keystrokes, let go with the quiet around them. Before a speaker is heard, soft sound the
/// discriminator called speech that never ran clear of the room is one too, sounding 0 s.
public struct Transients: Hashable, Sendable {
    public let count: Int
    /// Seconds the longest of them sounded without a break.
    public let longest: TimeInterval

    public static let none = Transients(count: 0, longest: 0)

    public init(count: Int, longest: TimeInterval) {
        self.count = count
        self.longest = longest
    }
}

/// Why an utterance has no transcript. A closed set, so whoever reports one decides what
/// each case may say - the dictation log keeps the words a reading carries private - and a
/// new way to fail has to be named here before an engine can throw it.
/// [LAW:types-are-the-program]
public enum TranscriptionFailure: Error, CustomStringConvertible {
    /// The caller stopped waiting for the engine before its turn came.
    case cancelled
    /// Nothing sounded as long as a syllable: no clip stood clear of the room, none under a
    /// speaker's level was called speech, or what did sound was a transient. `peak` is the
    /// loudest sample heard, and `quiet` all of the audio, with the room it was judged against
    /// and what it refused.
    case nothingSpoken(peak: Float, quiet: Quiet)
    case vocabulary(VocabularyError)
    /// The engine read the audio and its reading could not become a transcript.
    case unreadable(WhisperKitTranscriberError)
    /// The engine's own library failed: a model, a decoder, a buffer. WhisperKit's errors
    /// (`WhisperError`) name a stage or a file, never what it read.
    case engine(any Error)

    public var description: String {
        switch self {
        case .cancelled: "the decode was cancelled before the engine took it"
        case .nothingSpoken(let peak, let quiet):
            "nothing spoken: the loudest sample was \(peak) over a room of \(quiet.room.map { "\($0)" } ?? "none heard"), \(quiet.refusedAsNotSpeech) s clear of it were called no speech, and \(quiet.transients.count) transient\(quiet.transients.count == 1 ? "" : "s") sounded at most \(quiet.transients.longest) s of the \(AudioClip.duration(for: Utterance.syllable)) s a syllable sounds"
        case .vocabulary(let refusal): "\(refusal)"
        case .unreadable(let reading): "\(reading)"
        case .engine(let error): "\(error)"
        }
    }
}

extension Transcriber {
    /// A clip heard all at once: an utterance whose whole audio arrives with the
    /// key-up, so there is nothing to hear early and no partial to show, unless the
    /// caller asks to be told what the passes before the last failed to read.
    ///
    /// [LAW:one-type-per-behavior] Batch decoding is the one-clip utterance, not a
    /// second path through the engine.
    public func transcribe(_ clip: AudioClip, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void = { _ in }) async throws(TranscriptionFailure) -> Transcription {
        try await transcribe(AsyncStream { continuation in
            continuation.yield(clip)
            continuation.finish()
        }, expecting: vocabulary, partial: partial)
    }
}

/// What the engine has heard of an utterance still being spoken.
///
/// [LAW:types-are-the-program] Two transcripts, not one with a flag per word: the
/// confirmed words are final and will appear verbatim in the transcript the
/// utterance ends with, while the tentative words are the engine's latest reading
/// of everything after them and the next partial may replace them entirely.
public struct Partial: Sendable {
    public let confirmed: Transcript
    public let tentative: Transcript
    /// Passes so far that changed the punctuation of a word two passes had agreed on.
    public let repunctuated: Int
    /// The passes so far the engine failed to read, none when it read every one.
    public let unread: Unread?

    /// Passes the engine failed to read, each leaving its reading to the next pass, and why
    /// the latest of them failed.
    public struct Unread: Sendable {
        public let passes: Int
        public let latest: TranscriptionFailure

        public init(passes: Int, latest: TranscriptionFailure) {
            self.passes = passes
            self.latest = latest
        }
    }

    public init(confirmed: Transcript, tentative: Transcript, repunctuated: Int, unread: Unread?) {
        self.confirmed = confirmed
        self.tentative = tentative
        self.repunctuated = repunctuated
        self.unread = unread
    }

    /// Everything heard so far, confirmed then tentative.
    public var reading: Transcript {
        Transcript(words: confirmed.words + tentative.words)
    }

    /// The reading as one line of text.
    public var text: String {
        reading.text
    }
}

/// How far into an utterance's confirmed words a reader has gone: each read hands out the
/// words past the ones already handed out.
///
/// [LAW:one-source-of-truth] The one reading of `Partial`'s promise that confirmed words only
/// grow and open the transcript the utterance ends with: the server's deltas and the words a
/// press commits at the cursor both go through it. A list no longer than what was already
/// handed out has nothing new in it, so an engine that broke the promise is handed nothing
/// twice rather than trapping the process that reads it.
public struct ConfirmedCursor: Sendable {
    private var handedOut = 0

    public init() {}

    /// The words of `heard` past those already handed out, which are handed out now.
    public mutating func advance(through heard: [Transcript.Word]) -> Transcript {
        let new = Transcript(words: Array(heard.dropFirst(handedOut)))
        handedOut = max(handedOut, heard.count)
        return new
    }
}
