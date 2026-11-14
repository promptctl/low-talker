import Dictation
import GrammaticalNumber
import Grants
import InputSource
import LoopLifecycle
import LowTalkerCore
import Onboarding
import Uptime

extension LowTalkerApp {
    /// One record of something the app did, as it did it. A test reads it as a value; the unified
    /// log is handed its `lines`. A record a part of the app already makes is carried whole,
    /// never told again in other words. [LAW:nothing-unseen] [LAW:one-source-of-truth]
    public enum Event {
        /// The engine's readiness changed, read at `at`.
        case engine(EngineReadiness, at: HostTime)
        case activity(Dictation.Activity)
        case hotkey(HotkeyStatus)
        case prompts(Prompting.Load)
        /// A reading of the config that moved nothing, because nothing ran before it or it was refused.
        case config(RunningConfig)
        /// A save, and each setting it moved with what came of moving it.
        case configMoved(RunningConfig, moved: [String])
        case lifecycle(LoopLifecycle.Event)
        /// The input method was selected as far as it could be, from `bundle`.
        case inputMethodSelected(InputMethodReadiness, bundle: String)
        /// The input method could not be selected.
        case inputMethodNotSelected(String)
        case supervisor(InputMethodSupervisor.Event)
        /// The input method's standing, the first time it is shown.
        case inputMethod(InputMethodStanding)
        /// A reading of the requirements.
        case onboarding(Readiness)
        /// A reading of the microphone grant.
        case privacy(MicrophoneAuthorization)
        /// A device report of the microphone's, and what it is doing after.
        case microphone(CaptureReport, doing: AudioCapture.Doing)
        case press(Dictation.Report)
        /// A failure that was no press: the loop's sessions could not be waited out.
        case loopFailed(Dictation.Failed)
        case held(HoldState)
        case heldUnkept(HeldUnkept)
        case heldUnrestored(HeldUnreadable)
        /// What a click on the word box came to.
        case box(BoxClick)

        /// The log line or lines this record is, in its category, with any words the person
        /// dictated apart so the log keeps them private.
        public var lines: [Line] {
            switch self {
            case .engine(let readiness, let now): [Line(.engine, .info, "model: \(readiness.readout(at: now))")]
            case .activity(let activity): [Line(.dictation, .info, "activity: \(String(describing: activity))")]
            case .hotkey(let status): [Line(.engine, .notice, "hotkey: \(status)")]
            case .prompts(let load): [Line(.config, .notice, "\(load)")]
            case .config(let running): [Line(.config, .notice, "config: \(running)")]
            case .configMoved(let running, let moved): [Line(.config, .notice, "config: \(running); moved [\(moved.joined(separator: "; "))]")]
            case .lifecycle(let event): [Line(.engine, .notice, "\(event)")]
            case .inputMethodSelected(let state, let bundle): [Line(.engine, .notice, "input method: \(state) from \(bundle)")]
            case .inputMethodNotSelected(let error): [Line(.engine, .error, "input method: \(error)")]
            case .supervisor(let event): [Line(.engine, .notice, "input method: \(event)")]
            case .inputMethod(let standing): [Line(.engine, .notice, "input method: \(standing)")]
            case .onboarding(let readiness):
                [Line(.engine, .notice, "onboarding: \(readiness.ready ? "ready" : "not ready")")]
                    + readiness.requirements.map { Line(.engine, .notice, "onboarding: \($0.name): \($0.reads)") }
            case .privacy(let microphone): [Line(.engine, .notice, "privacy: \(microphone)")]
            case .microphone(let report, let doing): [Line(.microphone, .notice, "\(report); now \(doing)")]
            case .press(let press): [Self.line(press)]
            case .loopFailed(let failed): [Self.line(failed, of: nil)]
            case .held(let state): [Line(.dictation, .notice, "held: \(state)")]
            case .heldUnkept(let unkept): [Line(.dictation, .fault, "held words: \(unkept)")]
            case .heldUnrestored(let unreadable): [Line(.dictation, .fault, "held words: \(unreadable)")]
            case .box(let click): [Line(.dictation, click.refused ? .error : .notice, "\(click)")]
            }
        }

        /// The press's own line, with what it showed while the key was down and what its
        /// microphone delivered. The words are private: they are what the person dictated.
        private static func line(_ press: Dictation.Report) -> Line {
            switch press.outcome {
            case .session(let session):
                Line(.dictation, .notice, "\(press.mode): \(session.description); \(press.record): ", dictated: session.transcription.transcript.text)
            case .usedAsModifier(let landed, let standing, let discarded):
                Line(.dictation, .notice, "\(press.mode): the chord was the modifier of a typed key, so the press was not dictation and nothing heard past its inserts is held or shown; \(counted(landed, "word", "words")) inserted before, \(standing) that may have been, \(discarded) heard after them discarded; \(press.record)")
            case .cancelled(let cancelled):
                Line(.dictation, .notice, "\(press.mode): the press was cancelled with Escape, so nothing of it is held, offered or shown; \(cancelled.description); \(press.record)")
            case .failed(let failed):
                line(failed, of: press)
            }
        }

        /// A dictation that did not happen, as readable as one that did: the facts in the clear and
        /// any words it carries private, as its type declares them. The microphone's record comes
        /// before the facts, which can be a whole Core ML error, so the 1 KB the unified log keeps
        /// of a line still holds it.
        private static func line(_ failed: Dictation.Failed, of press: Dictation.Report?) -> Line {
            let account = failed.failure.account
            let mode = press.map { " in \($0.mode)" } ?? ""
            let record = press.map { "; \($0.record)" } ?? ""
            let facts = "session failed\(mode): \(failed.kind)\(record) — \(account.facts)"
            return switch account.dictated {
            case nil: Line(.dictation, .error, facts)
            case let dictated?: Line(.dictation, .error, "\(facts); dictated: ", dictated: dictated)
            }
        }
    }

    /// One line of the unified log.
    public struct Line: Equatable, Sendable {
        public enum Category: String, Sendable {
            case engine, dictation, microphone, config
        }

        public enum Level: Sendable {
            case info, notice, error, fault
        }

        public let category: Category
        public let level: Level
        /// What the log keeps in the clear.
        public let text: String
        /// Words the person dictated, after `text`, which the log keeps private.
        public let dictated: String?

        init(_ category: Category, _ level: Level, _ text: String, dictated: String? = nil) {
            self.category = category
            self.level = level
            self.text = text
            self.dictated = dictated
        }
    }

    /// What a click on the word box came to. Counted, never the words: they are what the person
    /// dictated.
    public enum BoxClick: Equatable, Sendable, CustomStringConvertible {
        case askedToInsert(words: Int, listening: Bool)
        case askedToBringBack(words: Int, listening: Bool)
        case copied(characters: Int)
        case copyRefused(characters: Int)
        case nothingToCopy

        var refused: Bool {
            if case .copyRefused = self { true } else { false }
        }

        public var description: String {
            switch self {
            case let .askedToInsert(words, listening):
                "asked to insert \(counted(words, "held word", "held words"))\(listening ? "" : ", with no loop listening to insert them")"
            case let .askedToBringBack(words, listening):
                "asked to bring back \(counted(words, "dismissed word", "dismissed words"))\(listening ? "" : ", with no loop listening to bring them back")"
            case .copied(let characters):
                "copied \(counted(characters, "character", "characters")) of held words, and dismissed them"
            case .copyRefused(let characters):
                "the pasteboard refused \(counted(characters, "character", "characters")) of held words"
            case .nothingToCopy:
                "asked to copy the held words with none held, so the clipboard is left as it was"
            }
        }
    }
}
