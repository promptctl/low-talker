import Grants
import Identity
import LowTalkerCore
import Onboarding
import Serve
import Uptime

/// Everything the status item's menu says, as rows, decided from one set of readings taken as the
/// menu opens. AppKit draws the rows and runs their actions; nothing it draws is decided there.
/// [LAW:effects-at-boundaries] [LAW:one-source-of-truth]
public struct Menu {
    /// What the menu is drawn from, each read at the moment the menu opens.
    public struct Readings {
        public var engine: EngineReadiness
        /// The instant the menu opened, on the app's clock, which a wait's readout is measured to.
        public var now: HostTime
        /// What the server is doing and whether the person chose it, in a build that can serve.
        public var serving: (state: ServerSwitch.State, chosen: Bool)?
        public var microphone: AudioCapture.Doing
        public var hotkey: HotkeyStatus
        /// Whether this installation's input method is the input source in use: it types only then.
        public var inputMethodSelected: Bool
        /// What macOS does with the Globe key, from System Settings.
        public var globeKey: GlobeKeyAction
        /// The config the app runs on, nil until it is first read.
        public var running: RunningConfig?
        public var lastFailure: String?
        public var lastReplacement: String?
        /// What keeping the held words for the next launch failed at.
        public var heldTroubles: [String]
        /// How many words the box's circle let go, while there are any to bring back.
        public var dismissedWords: Int?
        /// Speech no engine has read yet: what the menu says of it, and its seconds while any is kept.
        public var keptSpeech: (lines: [String], seconds: Int?)
        public var benchRunning: Bool
        public var readiness: Readiness
        public var openAtLogin: LoginItemStatus
        public var returnHolds: Bool

        public init(
            engine: EngineReadiness, now: HostTime, serving: (state: ServerSwitch.State, chosen: Bool)?,
            microphone: AudioCapture.Doing, hotkey: HotkeyStatus, inputMethodSelected: Bool, globeKey: GlobeKeyAction,
            running: RunningConfig?, lastFailure: String?, lastReplacement: String?, heldTroubles: [String],
            dismissedWords: Int?, keptSpeech: (lines: [String], seconds: Int?), benchRunning: Bool, readiness: Readiness,
            openAtLogin: LoginItemStatus, returnHolds: Bool
        ) {
            self.engine = engine
            self.now = now
            self.serving = serving
            self.microphone = microphone
            self.hotkey = hotkey
            self.inputMethodSelected = inputMethodSelected
            self.globeKey = globeKey
            self.running = running
            self.lastFailure = lastFailure
            self.lastReplacement = lastReplacement
            self.heldTroubles = heldTroubles
            self.dismissedWords = dismissedWords
            self.keptSpeech = keptSpeech
            self.benchRunning = benchRunning
            self.readiness = readiness
            self.openAtLogin = openAtLogin
            self.returnHolds = returnHolds
        }
    }

    /// One line of the menu.
    public enum Row: Equatable, Sendable {
        /// A line the menu says and nothing a reader can press.
        case readout(String)
        /// A line that says what failed, which a click copies whole.
        case failed(String, FailedLine)
        /// Something the person can choose, with its checkmark where it has one.
        case item(String, Action, check: Check?)
        case separator
    }

    /// Which of the menu's lines failed, as the log names it when that line is copied.
    public enum FailedLine: String, Sendable {
        case model, server, microphone, hotkey, lastDictation, heldWords, keptSpeech, config
    }

    public enum Action: Sendable {
        case bringBackDismissed, discardKeptSpeech, openSetUp, openBench, toggleOpenAtLogin, toggleReturnHold,
             toggleServing, openNotices, quit

        /// The key that, with Command, chooses the item: Quit's alone, as every Mac app's.
        public var keyEquivalent: String {
            switch self {
            case .quit: "q"
            case .bringBackDismissed, .discardKeptSpeech, .openSetUp, .openBench, .toggleOpenAtLogin, .toggleReturnHold,
                 .toggleServing, .openNotices: ""
            }
        }
    }

    public enum Check: Sendable {
        case on, off
        /// Chosen here, and not yet allowed elsewhere.
        case mixed
    }

    public let readings: Readings

    public init(_ readings: Readings) {
        self.readings = readings
    }

    /// Why the words of a press would be held rather than typed now: the input method types only
    /// while its source is the one in use. Empty while it is. The chord is heard either way.
    ///
    /// [LAW:no-silent-failure] A hotkey line that read as working while nothing could type
    /// would send the person after a broken app rather than the Input menu.
    public var untypedBecause: [String] {
        readings.inputMethodSelected ? [] : ["\(AppIdentity.displayName) is not the selected input source"]
    }

    /// What macOS also does with the Fn key when a chord the config listens for holds it, or nil.
    public var globeKeyClash: String? {
        switch readings.running?.config {
        case .success(let config)?: readings.globeKey.clash(with: config.modes.chords)
        // The status line already says why no chord is heard.
        case .failure?, nil: nil
        }
    }

    /// Every line, in the order the menu shows them.
    public var rows: [Row] {
        let r = readings
        var rows: [Row] = []
        let model = "Model: \(r.engine.readout(at: r.now))"
        let modelRow: Row = if case .failed = r.engine { .failed(model, .model) } else { .readout(model) }
        rows.append(modelRow)
        // A press made during the wait is not lost, and nothing else on screen says so.
        if case .preparing = r.engine { rows.append(.readout("A press now is heard once the model is ready")) }
        // Beside the model it answers with. [LAW:dataflow-not-control-flow] The offline build
        // has no switch, so no line.
        if let serving = r.serving {
            let server = "Server: \(serving.state)"
            let serverRow: Row = if case .stopped = serving.state { .failed(server, .server) } else { .readout(server) }
            rows.append(serverRow)
        }
        // What the microphone is doing: the menu-bar indicator says the device is open and only
        // this says why, so a lit microphone on an idle Mac is explained here or is a bug.
        let mic = "Microphone: \(r.microphone)"
        let micRow: Row = if case .stopped = r.microphone { .failed(mic, .microphone) } else { .readout(mic) }
        rows.append(micRow)
        let hotkey = "Hotkey: \(r.hotkey)"
        let hotkeyRow: Row = if case .off = r.hotkey { .failed(hotkey, .hotkey) } else { .readout(hotkey) }
        rows.append(hotkeyRow)
        rows += untypedBecause.map { .readout("    Not typed now: \($0)") }
        rows += [globeKeyClash].compactMap { $0 }.map { .readout("    \($0)") }
        rows += [r.lastFailure].compactMap { $0 }.map { .failed($0, .lastDictation) }
        rows += [r.lastReplacement].compactMap { $0 }.map { .readout($0) }
        // A fact about the store, not the words, and one the box has nothing to show for when
        // nothing is held. [LAW:no-silent-failure]
        rows += r.heldTroubles.map { .failed("Held words: \($0)", .heldWords) }
        // The one step back from a click on the box's circle.
        rows += [r.dismissedWords].compactMap { $0 }.map { .item("Bring Back Dismissed Words (\($0))", .bringBackDismissed, check: nil) }
        // Speech a press said before the model had loaded: how much, why it is not yet words, and
        // the person's one discard of it. [LAW:nothing-unseen]
        rows += r.keptSpeech.lines.map { .failed($0, .keptSpeech) }
        rows += [r.keptSpeech.seconds].compactMap { $0 }.map { .item("Discard Kept Speech (\($0) s)", .discardKeptSpeech, check: nil) }
        if let running = r.running, running.refusal != nil { rows.append(.failed("Config: \(running)", .config)) }
        if r.benchRunning { rows.append(.readout("A benchmark is running: the next press heard stops it")) }
        // Every requirement, met or not, and its step under it as the lines it was written in, so
        // a reader can tell "checked and fine" from "never checked". [LAW:dataflow-not-control-flow]
        for requirement in r.readiness.requirements {
            rows.append(.readout("\(requirement.name): \(requirement.reads)"))
            rows += requirement.stepLines.map { .readout("    \($0)") }
        }
        // The way into the guided setup, always there, and saying how much is left in it.
        let left = r.readiness.unmet.count
        rows.append(.item("\(GuidedSetup.title)\(left == 0 ? "" : " (\(left) left)")", .openSetUp, check: nil))
        rows.append(.item("Benchmark…", .openBench, check: nil))
        let login: Check = switch r.openAtLogin {
        case .on: .on
        case .requiresApproval: .mixed
        case .off, .unrecognized: .off
        }
        rows.append(.item("Open at Login", .toggleOpenAtLogin, check: login))
        // Anything but plainly on or off is said under the item, since a checkmark cannot say it.
        if r.openAtLogin != .on, r.openAtLogin != .off { rows.append(.readout("    \(r.openAtLogin)")) }
        // On, a Return typed while dictating is sent after the dictated words; the input method
        // holds a Return only when this is on.
        rows.append(.item("Hold Return for Dictated Words", .toggleReturnHold, check: r.returnHolds ? .on : .off))
        if let serving = r.serving { rows.append(.item("Serve Transcription", .toggleServing, check: serving.chosen ? .on : .off)) }
        rows.append(.separator)
        rows.append(.item("Acknowledgements", .openNotices, check: nil))
        rows.append(.item("Quit \(AppIdentity.displayName)", .quit, check: nil))
        return rows
    }

    /// What the opening read, for the log, beside what the rows say: the readings a person
    /// cannot see from the rows alone. [LAW:nothing-unseen]
    var lines: [LowTalkerApp.Line] {
        [
            LowTalkerApp.Line(.engine, .notice, "microphone at rest: \(readings.microphone)"),
            LowTalkerApp.Line(.engine, .notice, "hotkey: words held, not typed, because [\(untypedBecause.joined(separator: "; "))]"),
            LowTalkerApp.Line(.engine, .notice, "hotkey: Globe key \(String(describing: readings.globeKey)); \(globeKeyClash ?? "no clash with the chords")"),
            LowTalkerApp.Line(.login, .notice, "open at login: \(readings.openAtLogin)"),
        ]
    }
}
