import Foundation
import GrammaticalNumber
import LowTalkerCore
import os
import Uptime

/// The one consumer of speech no engine heard: it keeps it, and once an engine has landed reads it
/// into words and hands them to the `Hold`.
///
/// [LAW:one-source-of-truth] The pipeline is audio, then words, then placed. The `Hold` owns every
/// word no cursor took and stays the only owner of those; this owns speech that is not yet words,
/// and its one hand-off is `Hold.heldBack`. The hand-off is an operation on the loop's own
/// `SerialQueue`, the turn every insert, offer and bring-back runs in, so it can never fall between
/// an insert's `sending` and its answer, where `heldBack` would erase the mark of an insert on its
/// way and the next insert would type the words again. [LAW:single-enforcer]
///
/// One for the life of the app, as the `Hold` is, so the speech and the turn outlive every loop
/// rebuilt over a new config.
@MainActor
public final class Recovery {
    /// What the hold shows beside words that were said before the model had loaded.
    static let warning = "WARNING: These words were said before the model had loaded, and were read from what the microphone kept."

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "recovery")

    private let store: any UnheardStore
    private let hold: Hold
    private let sessions: SerialQueue
    /// Speech kept and not yet words, oldest first.
    public private(set) var kept: [UnheardEntry]
    /// Files the store could not read when it was opened, and what became of each, and removals
    /// that failed after the words were held. [LAW:no-silent-failure]
    public private(set) var troubles: [String]
    /// Why an engine could not read a kept speech, and which landing it was, by the speech's id.
    /// It stays kept and listed until the person discards it, and each engine that lands after
    /// reads it again: a save naming another model lands one that may read what this one could
    /// not, such as speech kept with a vocabulary Parakeet cannot be told.
    private var unread: [String: (why: String, landing: Int)] = [:]
    private var engine: (any Transcriber)?
    /// Engines landed so far; the latest is `engine`.
    private var landing = 0
    private var recovering: Task<Void, Never>?

    /// What a read of kept speech is timed on.
    private let clock: HostClock

    public init(store: any UnheardStore, hold: Hold, sessions: SerialQueue, clock: HostClock = .system) {
        self.store = store
        self.clock = clock
        self.hold = hold
        self.sessions = sessions
        let read = store.entries()
        kept = read.entries
        troubles = read.setAside
        for line in read.setAside { Self.log.fault("\(line, privacy: .public)") }
        if !read.entries.isEmpty {
            Self.log.notice("\(counted(read.entries.count, "kept speech was found", "kept speeches were found"), privacy: .public) at launch, \(Self.seconds(read.entries), privacy: .public) s, waiting for the model")
        }
    }

    /// Keeps speech no engine heard, which is read as soon as an engine has landed, or when one does.
    ///
    /// [LAW:nothing-unseen] A speech the store could not keep is lost, and the log says so whatever
    /// the press's report names first: a refused commit is named ahead of it.
    public func keep(_ speech: UnheardSpeech) throws(UnheardFault) {
        do throws(UnheardFault) {
            kept.append(try store.keep(speech))
        } catch {
            Self.log.fault("\(speech.seconds, privacy: .public) s of speech no engine heard could not be kept, and is lost: \(error.description, privacy: .public)")
            throw error
        }
        Self.log.notice("kept \(speech.seconds, privacy: .public) s of speech no engine heard")
        recover()
    }

    /// An engine has landed. It does not wait for anything: it starts the one task that reads
    /// what is kept, so the load that calls it never waits on a decode, which would wait on the
    /// press that holds the engine while that press waits on the load.
    ///
    /// `served` is the engine as a served caller, whose every pass waits while any press holds the
    /// engine, so reading kept speech never holds up a press.
    public func landed(_ served: any Transcriber) {
        engine = served
        landing += 1
        recover()
    }

    /// Lets go of every kept speech, as the person's one discard of speech that is not yet words.
    /// A speech being read finds itself gone when it comes to hand its words over, and hands
    /// none.
    public func discard() {
        recovering?.cancel()
        for entry in kept {
            do throws(UnheardFault) { try store.remove(entry) } catch { troubles.append("kept speech \(entry.id) could not be removed: \(error)") }
        }
        Self.log.notice("the person discarded \(counted(self.kept.count, "kept speech", "kept speeches"), privacy: .public), \(Self.seconds(self.kept), privacy: .public) s")
        kept = []
        unread = [:]
    }

    /// Whole seconds of speech kept, as the menu counts them.
    public var keptSeconds: Int { Self.seconds(kept) }

    /// What the menu says: how much speech is kept and why it is not yet words, then every
    /// trouble with the store. Never the words, which are not yet words.
    public var lines: [String] {
        let waiting = kept.filter { unread[$0.id] == nil }
        let failed = kept.filter { unread[$0.id] != nil }
        var lines: [String] = []
        if !waiting.isEmpty { lines.append("Speech waiting for the model: \(Self.spoken(waiting))") }
        if !failed.isEmpty {
            let causes = Set(failed.compactMap { unread[$0.id]?.why }).sorted().joined(separator: "; ")
            lines.append("Speech the model could not read: \(Self.spoken(failed)) (\(causes))")
        }
        return lines + troubles
    }

    /// Returns once nothing is being read, for a test or a caller that must know.
    public func settled() async {
        while let recovering { await recovering.value }
    }

    /// `keep` is called from inside the loop's turn, whose queue refuses a wait from any task that
    /// inherits it, and the hand-off in `read` is such a wait: so the run is detached.
    private func recover() {
        guard recovering == nil, engine != nil, kept.contains(where: untried) else { return }
        recovering = Task.detached { [self] in await run() }
    }

    /// Whether the latest engine has yet to read `entry`.
    private func untried(_ entry: UnheardEntry) -> Bool {
        unread[entry.id]?.landing != landing
    }

    /// Reads each kept speech not yet tried, oldest first, each either removed or marked unread:
    /// one that fails neither blocks the speech behind it nor is tried again. Ends, and says so,
    /// in the same step as it finds nothing left to read, so a speech kept in between starts
    /// another run. A run a discard cancelled ends the same way, and speech kept since the
    /// discard gets the run that follows. [LAW:no-ambient-temporal-coupling]
    private func run() async {
        while !Task.isCancelled, let engine, let entry = kept.first(where: untried) {
            await read(entry, on: engine, landing: landing)
        }
        recovering = nil
        recover()
    }

    private func read(_ entry: UnheardEntry, on engine: any Transcriber, landing: Int) async {
        let samples: [Float]
        let vocabulary: Vocabulary
        do {
            samples = try store.samples(of: entry)
            vocabulary = try Vocabulary(entry.vocabulary.map { try Vocabulary.Term($0) })
        } catch {
            return fail(entry, "\(error)", landing: landing)
        }
        let began = clock.now
        let transcription: Transcription
        do throws(TranscriptionFailure) {
            transcription = try await engine.transcribe(Self.audio(samples), expecting: vocabulary, partial: { _ in })
        } catch {
            switch error {
            case .cancelled:
                // A discard cancelled this task and has cleared what was kept; a cancel from
                // anywhere else is a failure to read it, or this would try it again forever.
                return Task.isCancelled ? () : fail(entry, "\(error)", landing: landing)
            case .nothingSpoken:
                Self.log.notice("kept speech \(entry.id, privacy: .public) held nothing spoken, so it was let go")
                return finish(entry)
            case .vocabulary, .unreadable, .engine: return fail(entry, "\(error)", landing: landing)
            }
        }
        let words = transcription.transcript
        guard !words.isBlank else {
            Self.log.notice("kept speech \(entry.id, privacy: .public) read as no words, so it was let go")
            return finish(entry)
        }
        let handed: Bool
        do throws(SerialQueueError) {
            handed = try await sessions.submit { [self] in await handOver(words, of: entry) }.value
        } catch {
            // The queue refuses only a wait from inside itself, which the main actor is not.
            preconditionFailure("kept speech could not be handed to the hold: \(error)")
        }
        if handed {
            Self.log.notice("read \(entry.seconds, privacy: .public) s of kept speech into \(counted(words.words.count, "held word", "held words"), privacy: .public) in \(began.duration(to: self.clock.now), privacy: .public)")
            finish(entry)
        } else {
            Self.log.notice("kept speech \(entry.id, privacy: .public) was discarded while it was being read, so its words were dropped")
        }
    }

    /// Holds the words, in the loop's turn, unless the person discarded the speech they were read
    /// from while it was being read: that is seen here, in the turn, and not before it.
    private func handOver(_ words: Transcript, of entry: UnheardEntry) -> Bool {
        guard kept.contains(entry) else { return false }
        hold.heldBack(words, by: nil, warning: Self.warning)
        return true
    }

    /// The speech is words, or nothing, and is no longer kept. A file that cannot be removed is told
    /// as a trouble: its words are held, so a launch that read it again would hold them twice.
    private func finish(_ entry: UnheardEntry) {
        do throws(UnheardFault) { try store.remove(entry) } catch { troubles.append("kept speech \(entry.id) could not be removed: \(error)") }
        kept.removeAll { $0 == entry }
        unread[entry.id] = nil
    }

    private func fail(_ entry: UnheardEntry, _ why: String, landing: Int) {
        unread[entry.id] = (why, landing)
        Self.log.fault("kept speech \(entry.id, privacy: .public) could not be read: \(why, privacy: .public)")
    }

    private static func audio(_ samples: [Float]) -> AsyncStream<AudioClip> {
        AsyncStream { audio in
            for clip in AudioClip(samples: samples).chunks(of: 1) { audio.yield(clip) }
            audio.finish()
        }
    }

    private static func seconds(_ entries: [UnheardEntry]) -> Int {
        Int(entries.reduce(0) { $0 + $1.seconds }.rounded())
    }

    private static func spoken(_ entries: [UnheardEntry]) -> String {
        "\(seconds(entries)) s"
    }
}
