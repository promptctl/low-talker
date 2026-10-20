import AppKit
import Bench
import Carbon
import Dictation
import Identity
import Grants
import InputSource
import Insertion
import LoopLifecycle
import LowTalkerCore
import MenuBarPresence
import Onboarding
import ServiceManagement
import Serve
import Signals
import StatusMenu
import os

/// The menu-bar agent. `LSUIElement` keeps it out of the Dock, so the status item
/// is the app's only surface; the delegate exists to install it, to start the model
/// loading the moment the app is up, and to hand the loop its microphone, engine and
/// input method.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // [LAW:no-ambient-temporal-coupling] NSStatusBar is only usable once the
    // application object exists, which is after this delegate is allocated. Lazy
    // creation ties the item's lifetime to first use instead of to an optional that
    // every later reader would have to unwrap.
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        return item
    }()

    /// The one menu, emptied and rebuilt from a fresh reading every time it is about to
    /// be shown. It holds no state of its own: what a reader sees is what
    /// `menuNeedsUpdate` just read, never a title some earlier code path remembered to
    /// keep in step. [LAW:one-source-of-truth]
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    /// What the engine is doing, and whether the hotkey is being watched. The two
    /// things in the menu that cannot be read on demand: they arrive from the load's
    /// and the loop's own callbacks, so they are held here while everything else is read
    /// at the moment the menu opens.
    ///
    /// The engine's is also the status icon's face, since a first load runs for minutes
    /// and an icon that looks ready through them reads as an app that is not answering.
    /// Lazy so it can count from `launched`; only `show(_:)` sets it, which redraws the icon.
    private lazy var engineReadiness: EngineReadiness = .preparing(nil, since: launched)
    private var hotkeyStatus: HotkeyStatus = .starting(step: nil)
    /// What the loop is doing with presses, which the icon shows over the engine's readiness.
    private var activity: Dictation.Activity = .idle
    /// The loop's activity again, floating over the app being dictated into, with the words
    /// no cursor took.
    private lazy var hud: HUD = HUD(dismiss: { [unowned self] in hold.dismiss() }, insert: { [unowned self] in
        // [LAW:nothing-unseen] A click with no loop to insert through places nothing, and says so.
        let words = hold.held?.allWords.words.count ?? 0
        let unheard = listening == nil ? ", with no loop listening to insert them" : ""
        sessions.notice("asked to insert \(words) held words\(unheard, privacy: .public)")
        listening?.dictation.insertHeld()
    })
    /// The words no cursor took, for the life of the app and past it: a loop rebuilt over a
    /// new config keeps offering them, and so does the next launch.
    private lazy var hold: Hold = Hold(store: HeldFile.app, failedToKeep: { [unowned self] unkept in
        sessions.fault("held words: \(unkept, privacy: .public)")
    }) { [unowned self] held in
        showHUD(held: held)
        // [LAW:nothing-unseen] Counted, never the words themselves: they are what the user dictated.
        sessions.notice("held: \(held.map { "\($0.allWords.words.count) words, \($0.standing?.words.words.count ?? 0) of them may have been typed, \($0.warnings.joined(separator: " "))" } ?? "nothing", privacy: .public)")
    }

    /// When this process began, which every readout of the engine's wait counts from.
    private let launched = ContinuousClock.now

    /// The same readouts in the unified log, where `log show` can time them: a menu
    /// nobody has open is no way to measure a launch, and no way for an agent to check
    /// what the app is showing without a screen. [LAW:verifiable-goals]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "engine")
    /// Each press's activity as it changes, then one line for its outcome: what was heard, how
    /// long after key-up, and what was inserted.
    private let sessions = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "dictation")

    /// [LAW:one-source-of-truth] Every engine status passes through here, so the
    /// menu and the log never tell different stories.
    private func show(_ readiness: EngineReadiness) {
        engineReadiness = readiness
        drawStatusIcon()
        log.info("model: \(readiness.readout(at: .now), privacy: .public)")
    }

    private func show(_ activity: Dictation.Activity) {
        self.activity = activity
        drawStatusIcon()
        showHUD(held: hold.held)
        sessions.info("activity: \(String(describing: activity), privacy: .public)")
    }

    private func showHotkeyStatus(_ status: HotkeyStatus) {
        hotkeyStatus = status
        showHUD(held: hold.held)
        log.notice("hotkey: \(status, privacy: .public)")
    }

    /// Every device report the microphone answers and every move of its resting mode, and
    /// what it is doing after, so a device that went away and the recovery that followed - or
    /// did not - and a saved mode that did or did not open the microphone read in `log show`
    /// without a press or a menu to show them. [LAW:nothing-unseen]
    private lazy var capture: AudioCapture = AudioCapture { [unowned self] report in
        microphoneLog.notice("\(report, privacy: .public); now \(self.capture.doing, privacy: .public)")
    }
    private let microphoneLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "microphone")

    /// A signal is a third way to ask the app to go, after the menu item and Cmd-Q, and
    /// it goes the same way they do rather than by the default disposition, which ends
    /// the process where it stands - with a session's words still on their way, if one is
    /// in flight. [LAW:single-enforcer] `terminate` is the door; this only knocks on it.
    ///
    /// The knock is posted to the main run loop rather than made from the handler, and
    /// that is load-bearing: `terminate` answers `.terminateLater` by spinning a nested
    /// event loop until the reply comes, and the reply is a main-queue block, which
    /// cannot run while another main-queue block is still on the stack. A handler that
    /// called `terminate` itself would hang the app it was trying to end. Every other way
    /// in reaches `terminate` from the run loop, and so does this - in the common modes,
    /// so an open menu or alert is not a signal ignored, and with the run loop woken, since
    /// a performed block waits for the loop's next wake (CFRunLoopPerformBlock) and an idle
    /// alert has nothing else to wake it. [LAW:no-ambient-temporal-coupling]
    ///
    /// Held from the moment the delegate exists, which is before the run loop starts: a
    /// signal arriving in that window is answered as the first thing the running app does.
    private let signals = SignalWatch { _ in
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The engine, from the moment launch starts loading it. Awaiting the task is how
    /// a session gets the transcriber; a task still running is the app's "still
    /// loading" state, held here rather than inside the engine.
    ///
    /// [LAW:no-ambient-temporal-coupling] Nothing can call the transcriber before it
    /// is resident: the only handle is the task, and the task yields the value only
    /// when the initializer has returned. Lazy so that it can name `loadEngine`, which
    /// reports to this delegate's menu; touching it is what starts the load.
    private lazy var engine: Task<WhisperKitTranscriber, any Error> = Task { try await loadEngine() }

    /// Whose decode the engine runs next: every press holds it from key-down, so a served
    /// caller waits for the speaker. Made with the delegate rather than with the engine, so
    /// a press that begins while the model still loads is already holding it when the
    /// server's first caller arrives. [LAW:single-enforcer]
    private let turns = EngineTurns()

    /// The transcription server, answering with `engine` once it is resident, so a caller is
    /// heard by the model dictation already holds and never a second copy of it. Nil in the
    /// offline build, which cannot accept a connection and so shows nothing about serving.
    private lazy var serving = ServerSwitch.ifEntitled()

    // MARK: - the loop

    /// The config this app runs on, read the first time it is asked for and again at every
    /// save: what the microphone does at rest, the modes the hotkey listens for and where
    /// the server listens, from one reading, so none of them comes from a different version
    /// of the file. The menu's names for the chords read it too, so what the menu says to
    /// hold is what is heard. Only `follow` changes it once it is read. [LAW:one-source-of-truth]
    private lazy var running = RunningConfig(reading: Result { () throws(ConfigError) in try Config.load() })
    private var config: Result<Config, ConfigError> { running.config }
    private let configLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "config")

    /// Takes up a save of the config file: each setting whose value changed is moved to the
    /// new value, and the rest are left alone. A save the file refused leaves every one where
    /// it was, and the menu says why. [LAW:no-silent-failure]
    ///
    /// Nothing here ends a press. A mode moved mid-hold leaves the hold to end at its own
    /// chord's release, heard in the mode it began in, and a resting mode moved mid-hold is
    /// taken up at the key-up.
    private func follow(_ next: RunningConfig) {
        let was = try? config.get()
        running = next
        // No config ran before this reading: the loop was held down for want of one, and comes
        // up the way it does at launch, whose status line says what still stops it - this
        // reading's refusal among them. A refusal with a config running before it reads as
        // that config, `.kept`, so it arrives below and moves nothing.
        guard let was, case .success(let now) = next.config else {
            configLog.notice("config: \(next, privacy: .public)")
            serving?.resume(at: config.map(\.serve))
            lifecycle.comeUp()
            return
        }
        // [LAW:nothing-unseen] Each moved setting lands on the event with what came of moving it.
        let moved = now.settings(changedFrom: was).map { setting in
            switch setting {
            case .modes:
                listening?.hotkey.listen(for: now.modes)
                // Only a line that says how to press is rewritten: one that says why nothing is
                // heard still says so. [LAW:no-silent-failure]
                if case .listening = hotkeyStatus { showHotkeyStatus(.listening(listeningStatus)) }
                return "modes \(now.modes)"
            case .microphone:
                // What the move comes to is its own report, once it lands.
                capture.rest(as: now.microphone)
                return "microphone \(capture.doing)"
            case .serve:
                serving?.resume(at: config.map(\.serve))
                return "server binding"
            }
        }
        configLog.notice("config: \(next, privacy: .public); moved [\(moved.joined(separator: "; "), privacy: .public)]")
    }

    /// The task following the config file's saves, ended by a quit.
    private var reloading: Task<Void, Never>?

    /// The loop that is listening now.
    private struct Listening {
        let hotkey: Hotkey
        let dictation: Dictation
        /// The input method's notices, hosted for as long as the hotkey is up. Nil when they or
        /// the hotkey could not come up, and then neither is.
        let notices: InputMethodNotices?

        /// [LAW:single-enforcer] Every teardown, in one order: the hotkey comes down and what
        /// it handed the main queue is delivered, then the notices stop, so the port's name is
        /// free for the loop built next.
        @MainActor func stop() async {
            await hotkey.stopAndDeliver()
            notices?.stop()
        }
    }

    private var listening: Listening?

    /// [LAW:one-source-of-truth] The panel, drawn from the loop's activity, what is held, and
    /// whether LowTalker is listening, as the menu says, to insert it. `held` is passed by the
    /// hold as it changes, since the hold calls here before it is assigned.
    private func showHUD(held: Held?) {
        let insertable = if case .listening = hotkeyStatus { true } else { false }
        hud.show(activity, held: held, insertable: insertable)
    }

    /// When the loop comes up, is rebuilt, or is left as it stands, and the one owner of the
    /// quit's refusal of anything new. Its events are the loop's lines in the log.
    /// [LAW:single-enforcer]
    private lazy var lifecycle = LoopLifecycle(
        startCapture: { [unowned self] in await startCapture() },
        adopt: { [unowned self] in await adopt() },
        requirementsMet: { [unowned self] in readReadiness().ready },
        watching: { [unowned self] in listening?.hotkey.isWatching == true },
        told: { [unowned self] in log.notice("\($0, privacy: .public)") })

    /// Why the last press's words reached no cursor, while no press has begun since.
    private var lastFailure: String?

    private func drawStatusIcon() {
        // Named, so the icon can be found by a reader with VoiceOver and by an agent
        // reading the bar over Accessibility.
        let description = activity.iconDescription(for: AppIdentity.displayName, over: engineReadiness)
        switch activity.glyph(over: engineReadiness) {
        case .mark:
            // The asset catalog marks it a template, so the bar tints it like its neighbours.
            // A copy, because the named image is shared and the description is this state's.
            // [LAW:no-silent-failure] A bundle without the mark is built wrong; the item keeps
            // a symbol rather than shrinking to nothing and taking the menu with it.
            guard let image = NSImage(named: AppIdentity.statusMarkName)?.copy() as? NSImage else {
                log.fault("no \(AppIdentity.statusMarkName, privacy: .public) in the asset catalog")
                statusItem.button?.image = NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: description)
                return
            }
            image.accessibilityDescription = description
            statusItem.button?.image = image
        case .symbol(let name):
            statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        }
    }

    /// Takes the loop down and builds it again: the old loop's hotkey comes down first,
    /// ending any press it had open, its sessions are waited out, and then the input method
    /// is installed and the hotkey goes up in front of a new loop. `lifecycle` decides when.
    private func adopt() async {
        if let previous = listening {
            listening = nil
            await previous.stop()
            // A refused wait is reported and the rebuild still made: a loop that cannot be
            // replaced would be the worse failure of the two. [LAW:no-silent-failure]
            do throws(SerialQueueError) { try await previous.dictation.finish() } catch { reportFailure(Dictation.Failed(error), of: nil) }
        }
        // [LAW:no-ambient-temporal-coupling] The input method is made ready before the hotkey
        // goes up, so no press is heard that has nowhere to go yet.
        showHotkeyStatus(.starting(step: "setting up the input method"))
        let installed = await selectInputMethod()
        // A loop is built only over capture holding the microphone, capture starts only over
        // a config that was read, and a save the file refused keeps the one that ran.
        guard case .success(let config) = config else { preconditionFailure("a loop is adopted only once the config has been read") }
        let hotkey = Hotkey(listeningFor: config)
        let dictation = Dictation(
            capture: capture,
            // A press asks the bench first: while a run holds the Neural Engine, the press is
            // refused and says why, so neither is measured against the other.
            transcriber: { [unowned self] () async throws(EngineUnavailable) in
                do {
                    try benchRuns.admitPress()
                    return try await engine.value
                } catch {
                    throw EngineUnavailable(error)
                }
            },
            turns: turns,
            // The words cross to the input method, which commits them at the
            // cursor through the text input system.
            executor: Executor(insertingThrough: InputMethodInserter()),
            hold: hold,
            report: { [unowned self] in report($0) },
            showing: { [unowned self] in show($0) }
        )
        // The hotkey goes up only over an input method that installed: a hotkey over one that
        // refused would open the microphone on every press for words that go nowhere, while
        // the status line said the loop was off. [LAW:no-silent-failure]
        //
        // And only over notices that were hosted. The input method tells each cursor it is
        // given focus in, and the loop listening then offers it what is held. The port's name
        // is one per login session, so a second copy of the app stops here and hears nothing.
        let notices = installed.flatMap {
            Result { () throws(PortNotHosted) in
                try InputMethodNotices(
                    cursorArrived: { [unowned self] in listening?.dictation.cursorArrived() },
                    superviseInputMethod: { [unowned self] in InputMethodSupervisor(told: { [unowned self] in show($0) }).stop })
            }.mapError { LoopRefusal(stringLiteral: "\($0)") }
        }
        // Notices whose hotkey did not go up are stopped with it, so their supervision says
        // nothing that would put a listening line over the refusal.
        let hearing = notices.flatMap { notices in
            Result {
                try hotkey.start { [unowned self] transition in
                    if case .began = transition { lastFailure = nil }
                    dictation.press(transition)
                }
                return notices
            }.mapError { error in
                notices.stop()
                return LoopRefusal(stringLiteral: "\(error)")
            }
        }
        listening = Listening(hotkey: hotkey, dictation: dictation, notices: try? hearing.get())
        // A hotkey that went up says how to press it once the input method's process is
        // running, which is that process's event to tell; see `show(_:)`.
        if case .failure(let refusal) = hearing { showHotkeyStatus(.off(refusal.reason)) }
    }

    /// The input method's process as the notices keep it: the line says how to press only
    /// while one is running, since nothing else can type the words.
    private func show(_ inputMethod: InputMethodSupervisor.Event) {
        log.notice("input method: \(inputMethod, privacy: .public)")
        switch inputMethod {
        case .running: showHotkeyStatus(.listening(listeningStatus))
        case .ended: showHotkeyStatus(.off("the input method ended; \(AppIdentity.displayName) is starting it again"))
        case .notOpened(let reason, _):
            showHotkeyStatus(.off("the input method could not be started: \(reason); trying again every \(InputMethodSupervisor.throttleInterval.formatted(.units(width: .wide)))"))
        }
    }

    /// This installation's input method, as its package installed it, registered and - once
    /// a person has switched it on in setup - selected: what the words are committed through
    /// and the hotkey is told the keys by. Run at every rebuild, which is what keeps the input
    /// method selected.
    ///
    /// Nothing here puts a system dialog on screen, because a rebuild runs at launch. The
    /// input method is switched on from its own step in setup; see `ask(_:)`.
    ///
    /// [LAW:no-silent-failure] A select that fails leaves a hotkey that would hear every
    /// press and insert nothing, so it comes back as a refusal for the status line.
    private func selectInputMethod() async -> Result<Void, LoopRefusal> {
        do {
            let inputMethod = InstalledInputMethod()
            let bundle = try inputMethod.bundle()
            let state = try await inputMethod.select()
            log.notice("input method: \(state, privacy: .public) from \(bundle.path, privacy: .public)")
            // Stopped short of selected only where a person has yet to switch it on,
            // which is a step in setup rather than something that went wrong.
            return state.ready ? .success(()) : .failure("""
                the input method is \(state); switch it on in \(GuidedSetup.title) \
                in this menu, where macOS asks you to allow it
                """)
        } catch {
            log.error("input method: \(String(describing: error), privacy: .public)")
            return .failure("the input method could not be selected: \(error)")
        }
    }

    /// Why the loop is not working, in the words the status line says it.
    /// Named apart from `Insertion.Refusal`, which is the input method's answer to an insert.
    private struct LoopRefusal: Error, ExpressibleByStringInterpolation {
        let reason: String
        init(stringLiteral reason: String) { self.reason = reason }
    }

    /// What the menu says after "Hotkey: ".
    private enum HotkeyStatus: CustomStringConvertible {
        case starting(step: String?)
        /// Listening, and how to press it.
        case listening(String)
        /// Not listening, for this reason.
        case off(String)

        var description: String {
            switch self {
            case .starting(nil): "starting…"
            case .starting(let step?): "starting — \(step)"
            case .listening(let howToPress): howToPress
            case .off(let reason): "off — \(reason)"
            }
        }
    }

    /// The status line of a hotkey that is listening.
    private var listeningStatus: String { "hold \(chordName), or tap it to start and again to stop" }

    /// The chords the config listens for, in the words a person presses them by.
    private var chordName: String {
        switch config {
        case .success(let config): Hotkey.named(in: config)
        // The status line already says why nothing is heard.
        case .failure: "no chord: the config cannot be read"
        }
    }

    // MARK: - the guided setup

    /// The guided setup, over the one list the menu reads.
    private lazy var setUp = SetUpWindow(
        read: { [unowned self] in readReadiness() },
        ask: { [unowned self] in await ask($0) },
        settle: { [unowned self] in lifecycle.settle(requirementsMet: $0.ready) }, log: log)

    /// Asks macOS for one requirement - the only place in the app that does, and reached
    /// only from the button a person pressed on that requirement's step. Each case raises
    /// at most one system dialog.
    ///
    /// Answers with how the request ended, and what went wrong for the step to show when
    /// something did. A person declining is not something that went wrong: the next reading
    /// shows the step still unmet, with what skipping it costs. [LAW:no-silent-failure]
    private func ask(_ row: Requirement.Row) async -> SetUpWindow.Request {
        switch row {
        case .microphone:
            // macOS asks about the microphone once. Past that, requesting answers at once and
            // shows nothing, so a decided "no" is said here and the pane opened instead.
            switch readMicrophone() {
            case .withheld(.notDetermined):
                // Asked here, as measured on studious 2026-09-24: one dialog, naming the app.
                _ = await MicrophonePermission().request()
                return .answered
            case .withheld(.denied):
                return .sentToSystemSettings("macOS asks only once. Turn on \(AppIdentity.displayName) in the \(row.rawValue) list in System Settings.")
            case .withheld(.restricted):
                return .failed("A policy on this Mac blocks the microphone.")
            case .granted:
                return .made
            }
        case .inputMethod:
            do { try await InstalledInputMethod().switchOn() } catch { return .failed("\(error)") }
            // Switched on is not selected: once it reads as met, the loop is rebuilt so the
            // install selects it, whether or not the loop is up.
            lifecycle.inputMethodWasSwitchedOn()
            return .made
        }
    }

    /// Only in the menu of a build that has a server to switch.
    @objc private func toggleServing() {
        serving.map { $0.choose(!$0.chosen, at: config.map(\.serve)) }
    }

    /// Opens the app at login, or stops it. An item switched off in System Settings can be
    /// allowed only there, so that refusal opens the pane at the switch; any other is said in
    /// an alert, since a click that shows nothing tells a person nothing. [LAW:no-silent-failure]
    @objc private func toggleOpenAtLogin() {
        do {
            let now = try loginItem.toggle()
            loginLog.notice("open at login: toggled; \(now, privacy: .public)")
        } catch {
            loginLog.error("open at login: refused: \(error, privacy: .public)")
            if error.allowedOnlyInSystemSettings { SMAppService.openSystemSettingsLoginItems() }
            else { NSAlert(error: error.reason).runModal() }
        }
    }

    private let loginItem = LoginItem()
    private let loginLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "login")

    @objc private func openSetUp() {
        setUp.show()
    }

    // MARK: - the bench

    /// The one bench run at a time, which presses ask before they take the engine. It holds
    /// the app's turns for a run, so a served request waits for it as for a press.
    private lazy var benchRuns = BenchRuns(turns: turns)

    private lazy var bench = BenchWindow(runs: benchRuns, carried: ModelStore.carried(by: .main))

    @objc private func openBench() {
        bench.show()
    }

    /// The notices the licenses of everything the bundle ships require, which the build
    /// writes into it from the SBOM. An agent app has no About window to hang them on, so
    /// this is the one way a person reaches them.
    ///
    /// A copy is what opens, never the file in the bundle: TextEdit opens a text file
    /// editable and autosaves it, and one keystroke saved into the bundle breaks the seal
    /// every grant is keyed to. A copy that cannot be made or opened is said in an alert,
    /// since a click that shows nothing tells a person nothing. [LAW:no-silent-failure]
    @objc private func openNotices() {
        do {
            guard let notices = Bundle.main.url(forResource: Notices.resource, withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: Notices.resource])
            }
            let copy = FileManager.default.temporaryDirectory.appending(path: Notices.resource)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: notices, to: copy)
            guard NSWorkspace.shared.open(copy) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: copy.path]) }
        } catch {
            log.error("could not open the notices: \(error, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - whether the icon is in the menu bar

    /// What has been seen of the status item since it was made, judged once at
    /// `StatusItemSighting.deadline`. Lazy so it is timed from its first reading, which
    /// `watchStatusItem` takes as the item is made.
    private lazy var sighting = StatusItemSighting(made: .now)
    private let menuBarLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "menubar")

    /// Reads the status item's window now and at every change of what of it is on screen, and
    /// at the deadline says how it went: in the log every time, and to the person when macOS
    /// is not showing the icon at all, since the icon is the app's only way in and an app
    /// running with none shows no sign of running. [LAW:no-silent-failure] [LAW:nothing-unseen]
    private func watchStatusItem() {
        sawStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(sawStatusItem), name: NSWindow.didChangeOcclusionStateNotification, object: statusItem.button!.window!)
        // A run loop timer and not a sleeping Task, because the judging can raise a modal
        // alert: a Task runs as a main-queue block, and none other runs while it is on the
        // stack, so the main actor's work and the quit's reply would wait on the person
        // (measured 2026-10-18: a SIGTERM under the alert hung the quit). The run loop serves
        // the main queue inside a modal it is called out from. [LAW:no-ambient-temporal-coupling]
        after(StatusItemSighting.deadline - StatusItemSighting.placing) {
            let early = MenuBarUnseen.now()
            self.after(StatusItemSighting.placing) {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
                // A last reading of whatever window holds the button now, in case a change was
                // never posted.
                self.sawStatusItem()
                self.judge(self.sighting.verdict(menuBar: [early, .now()]))
            }
        }
    }

    private func after(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        RunLoop.main.add(Timer(timeInterval: delay / .seconds(1), repeats: false) { _ in MainActor.assumeIsolated(work) }, forMode: .common)
    }

    @objc private func sawStatusItem() {
        sighting.saw(onScreen: statusItem.button!.window!.occlusionState.contains(.visible), at: .now)
    }

    private func judge(_ verdict: StatusItemSighting.Verdict) {
        let notice = HiddenIconNotice.forThisMac()
        // Where the window stands, which is where a hidden one is parked.
        let seen = "\(verdict), its window at \(NSStringFromRect(statusItem.button!.window!.frame))"
        guard verdict == .hidden else {
            menuBarLog.notice("menu bar: \(seen, privacy: .public)")
            return
        }
        // Asking whether to keep running means nothing to an app already on its way out.
        guard !lifecycle.quitting else {
            menuBarLog.notice("menu bar: \(seen, privacy: .public); not said, as \(AppIdentity.displayName, privacy: .public) is quitting")
            return
        }
        guard !notice.silenced else {
            menuBarLog.notice("menu bar: \(seen, privacy: .public); not said, as the person asked")
            return
        }
        menuBarLog.notice("menu bar: \(seen, privacy: .public); told the person")
        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.body
        for answer in notice.answers { alert.addButton(withTitle: answer.title) }
        alert.showsSuppressionButton = true
        NSApp.activate()
        let response = alert.runModal()
        if alert.suppressionButton!.state == .on { notice.silence() }
        let silenced = notice.silenced ? ", and not to be told again" : ""
        guard let chosen = notice.answer(to: response) else {
            menuBarLog.error("menu bar: the alert ended with response \(response.rawValue) before the person chose\(silenced, privacy: .public)")
            return
        }
        menuBarLog.notice("menu bar: the person chose \(chosen.title, privacy: .public)\(silenced, privacy: .public)")
        switch chosen {
        case .openMenuBarSettings(let settings):
            if !NSWorkspace.shared.open(settings) { menuBarLog.error("menu bar: System Settings did not open \(settings, privacy: .public)") }
        case .keepRunning: break
        case .quit: NSApp.terminate(nil)
        }
    }

    // MARK: - launch and quit

    func applicationDidFinishLaunching(_ notification: Notification) {
        show(.preparing(nil, since: launched))
        statusItem.isVisible = true
        watchStatusItem()
        _ = engine
        // What the last run held is shown from launch, not from the first loop, which waits on
        // the microphone grant. [LAW:nothing-unseen] So is a store that could not be read.
        hold.unrestored.map { sessions.fault("held words: \($0, privacy: .public)") }
        // Listening from launch when the person last chose to, answering 503 until the model
        // is resident, so a client started beside the app is told to wait rather than refused.
        serving?.resume(at: config.map(\.serve))
        showHotkeyStatus(.starting(step: nil))
        Task { await listen() }
        // Read after `serving` and the loop's first reading of the config, so a save from
        // here on is a reload of the config they started on.
        reloading = Task { [running] in
            for await next in RunningConfig.reloads(after: running) { follow(next) }
        }
    }

    /// The loop as far as what is already granted allows, then the guided setup when
    /// something is left: every requirement stops dictation, so an app missing one can do
    /// nothing until the person has seen why.
    ///
    /// A launch asks for no grant. Every grant is asked for from its own step in setup,
    /// after that step has said why; see `ask(_:)`.
    private func listen() async {
        await lifecycle.comeUp().value
        if !readReadiness().unmet.isEmpty { setUp.show() }
    }

    /// The come-up's first step: the microphone grant read, then capture holding it. Answers
    /// what came of it; `lifecycle` builds the loop over it, last, so no press can
    /// arrive before there is a capture to open a microphone for it.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// Reads the grant and asks for none: a microphone not yet allowed leaves the loop down
    /// with the reason on the status line, and the setup's step is where it is asked for.
    ///
    /// What the microphone is doing when this returns is the resting mode's to say, which
    /// is the one thing the config decides here; `AudioCapture.start` is where that is
    /// written down. [LAW:one-source-of-truth]
    ///
    /// A config that cannot be read stops the app listening rather than being answered
    /// with the defaults, which is `ConfigError`'s own rule: "there is no config" and
    /// "there is a config I could not read" are different facts, and running the second
    /// one as the first would hold or release the microphone on settings its owner never
    /// chose. The menu says what is wrong with it.
    /// [LAW:no-silent-failure]
    private func startCapture() async -> LoopLifecycle.Capture {
        do {
            // A capture already running is left running: the microphone was held before, and
            // what came up short was the hotkey or the input method, which the rebuild redoes.
            // Restarting it would close and reopen an engine the resting mode holds open.
            guard capture.atRest == nil else { return .running }
            let grant = try readMicrophone().grant()
            let atRest = try config.get().microphone
            // Awaited, so the menu and the readings queued behind the come-up run while
            // a slow input is reached.
            try await capture.start(grant, atRest: atRest)
            return .started
        } catch {
            // Stopping is idempotent, so a grant withheld and a capture that failed to
            // start leave by one path. [LAW:dataflow-not-control-flow]
            capture.stop()
            // A microphone macOS was never asked about, or was told no, is a step in setup,
            // and the status says where it is the way the input method's refusal does.
            let whereToAllow = switch error {
            case MicrophoneAuthorization.Withheld.notDetermined, MicrophoneAuthorization.Withheld.denied:
                "; allow it in \(GuidedSetup.title) in this menu"
            default: ""
            }
            showHotkeyStatus(.off("\(error)\(whereToAllow)"))
            return .notStarted
        }
    }

    /// Quitting waits for the sessions: a press heard just before the quit still has its
    /// words on the way to the cursor, and the wait is what lets them land.
    /// [LAW:no-ambient-temporal-coupling] The quit has an owner, rather than a race.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let rebuilding = lifecycle.quit()
        // A save during the drain would rebind the server and move the microphone under it.
        reloading?.cancel()
        Task {
            // A rebuild in progress is let finish first, so the loop waited on is the last one.
            await rebuilding?.value
            // The hotkey comes down before the wait, as at every other teardown: a press open
            // when the quit arrives is ended as lapsed and reported, rather than the app
            // going mid-utterance leaving nothing behind to say it did, and no key-down
            // arriving during the wait can open a session there is no longer anyone to close.
            await listening?.stop()
            // Every session's audio ended at its key-up and no key-down can open another, so
            // the microphone goes now: a resting mode that holds it open does not hold it
            // through a drain that can wait minutes on a cold load.
            capture.stop()
            // A refused wait is reported and the quit still granted: an app that cannot
            // be quit would be the worse failure of the two. [LAW:no-silent-failure]
            do throws(SerialQueueError) { try await listening?.dictation.finish() } catch { reportFailure(Dictation.Failed(error), of: nil) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Off the main path from the first await: the Core ML load runs on WhisperKit's
    /// own threads, and only the status text comes back here.
    private func loadEngine() async throws -> WhisperKitTranscriber {
        do {
            // One operation and not two: the bundle carries a store and this loads it in
            // place — read-only, verified whole where the code signature sealed it, written
            // to never. A read-only store cannot be installed into, only confirmed and
            // loaded, so a carried store that lacks the model fails with its reason rather
            // than a permission error from a lock it could not take.
            //
            // There is deliberately no other way to reach a model from here, and a bundle
            // carrying none is a build error reported at launch rather than a download.
            // The branch that used to stand here fetched from Hugging Face when the bundle
            // carried nothing, which made a development build that had silently shipped
            // without its model look launchable and then reach the network from an app that
            // has no business doing so. Every bundle carries its model - `make app` fills
            // the store the same way scripts/sign-release does - so the case that branch
            // existed for is now a Makefile that did not run, which is worth being told
            // about in the words below. [LAW:types-are-the-program] [LAW:no-silent-failure]
            let report: @Sendable (WhisperKitTranscriber.LoadPhase) -> Void = { phase in
                Task { @MainActor in
                    let next = self.engineReadiness.reporting(phase)
                    if next != self.engineReadiness { self.show(next) }
                }
            }
            guard let carried = ModelStore.carried(by: .main) else { throw BundleCarriesNoModel() }
            let transcriber = try await WhisperKitTranscriber.loadInPlace(in: carried, turns: turns, phase: report)
            show(.ready(transcriber.model, after: launched.duration(to: .now)))
            serving?.answer(with: .ready(transcriber.served))
            return transcriber
        } catch {
            // [LAW:no-silent-failure] A model that failed to load is the one thing the
            // menu must say, since every session after this would otherwise fail
            // with no explanation on screen.
            show(.failed("\(error)"))
            serving?.answer(with: .failed("the model failed to load: \(error)"))
            throw error
        }
    }

    /// The press's own line, with what its microphone delivered; each insert's
    /// key-up-to-acknowledged time is the executor's line beside it, under its own category.
    /// The words are private: they are what the user dictated.
    private func report(_ press: Dictation.Report) {
        switch press.outcome {
        case .session(let session):
            sessions.notice("\(press.mode, privacy: .public): \(session.description, privacy: .public); microphone: \(press.microphone, privacy: .public): \(session.transcription.transcript.text, privacy: .private)")
        case .usedAsModifier(let landed, let held):
            sessions.notice("\(press.mode, privacy: .public): the chord was the modifier of a typed key, so nothing more of the press was inserted; \(landed, privacy: .public) words inserted before, \(held, privacy: .public) heard after them held; microphone: \(press.microphone, privacy: .public)")
        case .failed(let failed):
            reportFailure(failed, of: press)
        }
    }

    /// `press` is nil for a failure that was no press - the loop's sessions could not be
    /// waited out - which has no microphone to say.
    private func reportFailure(_ failed: Dictation.Failed, of press: Dictation.Report?) {
        // [LAW:no-silent-failure] The words went nowhere, or only some of them did, so the
        // menu says why.
        lastFailure = failureLine(failed.failure)
        // [LAW:nothing-unseen] A dictation that did not happen is as readable here as one
        // that did: the facts in the clear and any words it carries private, as its type
        // declares them.
        let account = failed.failure.account
        let mode = press.map { " in \($0.mode)" } ?? ""
        let microphone = press.map { "; microphone: \($0.microphone)" } ?? ""
        switch account.dictated {
        case nil:
            sessions.error("session failed\(mode, privacy: .public): \(failed.kind, privacy: .public) — \(account.facts, privacy: .public)\(microphone, privacy: .public)")
        case let dictated?:
            sessions.error("session failed\(mode, privacy: .public): \(failed.kind, privacy: .public) — \(account.facts, privacy: .public)\(microphone, privacy: .public); dictated: \(dictated, privacy: .private)")
        }
    }

    // MARK: - the menu

    /// What this installation's setup needs, read off this Mac now, and logged as it is read.
    ///
    /// The one reading every surface in the app draws from: the menu, the guided setup, and
    /// the question of whether setup has anything to show. Paid on every read rather than
    /// kept warm in the background because a cached reading is a reading that can be stale
    /// exactly when it matters: right after the user gave the grant the menu was telling them
    /// to give. [LAW:no-ambient-temporal-coupling]
    private func readReadiness() -> Readiness {
        let readiness = OnboardingProbe.readiness(microphone: readMicrophone())
        log.notice("onboarding: \(readiness.ready ? "ready" : "not ready", privacy: .public)")
        for requirement in readiness.requirements {
            log.notice("onboarding: \(requirement.name, privacy: .public): \(requirement.reads, privacy: .public)")
        }
        return readiness
    }

    /// The app's microphone authorization as it stands now.
    private func readMicrophone() -> MicrophoneAuthorization {
        let microphone = MicrophonePermission().current
        log.notice("privacy: \(microphone, privacy: .public)")
        return microphone
    }

    /// Why the words of a press would be held rather than typed right now, read at the moment
    /// the menu opens: the input method types only while its source is the one in use, and
    /// into nothing while an app holds Secure Event Input. Empty when neither stands in the way.
    /// The chord is heard either way.
    ///
    /// [LAW:no-silent-failure] A hotkey line that read as working while nothing could type
    /// would send the person after a broken app rather than the Input menu or the password
    /// field in front of them.
    private func untypedBecause() -> [String] {
        let reasons: [String?] = [
            InstalledInputMethod.isSelected() ? nil : "\(AppIdentity.displayName) is not the selected input source",
            IsSecureEventInputEnabled() ? "an app holds Secure Event Input, as a password field does" : nil,
        ]
        let found = reasons.compactMap { $0 }
        log.notice("hotkey: words held, not typed, because [\(found.joined(separator: "; "), privacy: .public)]")
        return found
    }

    /// What macOS also does with the Fn key when a chord the config listens for holds it, read
    /// at the moment the menu opens, so a setting changed in System Settings shows the next
    /// time it does. Nil when no chord holds Fn or the Globe key does nothing.
    private func globeKeyClash() -> String? {
        let stored = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        let action = GlobeKeyAction(appleFnUsageType: stored)
        let clash: String? = switch config {
        case .success(let config): action.clash(with: config.modes.chords)
        // The status line already says why no chord is heard.
        case .failure: nil
        }
        log.notice("hotkey: Globe key \(String(describing: action), privacy: .public); \(clash ?? "no clash with the chords", privacy: .public)")
        return clash
    }

    /// Everything the menu says, made here, every time, from what this Mac reads now.
    ///
    /// An `LSUIElement` app has no window to activate, so opening the menu is the moment
    /// to re-read. `menuNeedsUpdate` rather than `menuWillOpen`: AppKit calls this one
    /// before the menu is laid out, so the items are in place when it is measured.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let readiness = readReadiness()
        lifecycle.settle(requirementsMet: readiness.ready)

        // What the user's microphone is doing, on the surface the epic exists for: the
        // menu-bar indicator says the device is open and only this says why, so a lit
        // microphone on an idle Mac is either explained here or is a bug - and a dark one
        // the config asked to hold open says so here too. [LAW:no-silent-failure]
        let microphone = capture.doing
        log.notice("microphone at rest: \(microphone, privacy: .public)")
        let untyped = untypedBecause()
        let globeKey = globeKeyClash()
        let openAtLogin = loginItem.current
        loginLog.notice("open at login: \(openAtLogin, privacy: .public)")

        menu.removeAllItems()
        let model = "Whisper model: \(engineReadiness.readout(at: .now))"
        let modelRow = if case .failed = engineReadiness { errorRow(model, .model) } else { readout(model) }
        menu.addItem(modelRow)
        // A press made during the wait is not lost, and nothing else on screen says so.
        if case .preparing = engineReadiness { menu.addItem(readout("A press now is heard once the model is ready")) }
        // Beside the model it answers with. [LAW:dataflow-not-control-flow] The offline build
        // has no switch, so no line.
        serving.map { serving in
            let server = "Server: \(serving.state)"
            let serverRow = if case .stopped = serving.state { errorRow(server, .server) } else { readout(server) }
            menu.addItem(serverRow)
        }
        let mic = "Microphone: \(microphone)"
        let micRow = if case .stopped = microphone { errorRow(mic, .microphone) } else { readout(mic) }
        menu.addItem(micRow)
        let hotkey = "Hotkey: \(hotkeyStatus)"
        let hotkeyRow = if case .off = hotkeyStatus { errorRow(hotkey, .hotkey) } else { readout(hotkey) }
        menu.addItem(hotkeyRow)
        for reason in untyped { menu.addItem(readout("    Not typed now: \(reason)")) }
        globeKey.map { menu.addItem(readout("    \($0)")) }
        lastFailure.map { menu.addItem(errorRow($0, .lastDictation)) }
        // What keeping the held words for the next launch failed at: a fact about the store,
        // not the words, and one the panel has nothing to show for when nothing is held.
        // [LAW:no-silent-failure]
        for trouble in [hold.unrestored?.description, hold.unkept?.description].compactMap({ $0 }) {
            menu.addItem(errorRow("Held words: \(trouble)", .heldWords))
        }
        if running.refusal != nil { menu.addItem(errorRow("Config: \(running)", .config)) }
        if benchRuns.isRunning { menu.addItem(readout("A benchmark is running: presses are refused until it ends")) }
        // Every requirement, met or not, and its step under it as the lines it was
        // written in - one item per line, so nothing here wraps text the requirement
        // already broke. A list that showed only what was missing would leave a reader
        // unable to tell "checked and fine" from "never checked".
        // [LAW:dataflow-not-control-flow]
        for requirement in readiness.requirements {
            menu.addItem(readout("\(requirement.name): \(requirement.reads)"))
            for line in requirement.stepLines { menu.addItem(readout("    \(line)")) }
        }
        // The way into the guided setup, always there, and saying how much is left in it.
        let left = readiness.unmet.count
        let stepsLeft = left == 0 ? "" : " (\(left) left)"
        menu.addItem(withTitle: "\(GuidedSetup.title)\(stepsLeft)", action: #selector(openSetUp), keyEquivalent: "")
        menu.addItem(withTitle: "Benchmark…", action: #selector(openBench), keyEquivalent: "")
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        // Mixed while it waits on System Settings: chosen here, not yet allowed there.
        login.state = switch openAtLogin {
        case .on: .on
        case .requiresApproval: .mixed
        case .off, .unrecognized: .off
        }
        // Anything but plainly on or off is said under the item, since a checkmark cannot say it.
        if openAtLogin != .on, openAtLogin != .off { menu.addItem(readout("    \(openAtLogin)")) }
        serving.map { serving in
            let item = menu.addItem(withTitle: "Serve Transcription", action: #selector(toggleServing), keyEquivalent: "")
            item.state = serving.chosen ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Acknowledgements", action: #selector(openNotices), keyEquivalent: "")
        menu.addItem(withTitle: "Quit \(AppIdentity.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// A line the menu says and nothing a reader can press. An item with no action is
    /// one AppKit disables on its own, which is the whole of what "readout" means here.
    private func readout(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    /// Which of the menu's lines failed, as the log names it when that line is copied.
    private enum FailedLine: String {
        case model, server, microphone, hotkey, lastDictation, heldWords, config
    }

    /// A line that says what failed, which a click copies whole to the clipboard.
    private func errorRow(_ text: String, _ line: FailedLine) -> NSMenuItem {
        ErrorRow(text, copyingTo: .general) { [menuBarLog] copied in
            // [LAW:nothing-unseen] The count, not the text: a failure line can carry dictated words.
            if copied.taken {
                menuBarLog.notice("menu: copied the \(line.rawValue, privacy: .public) error row, \(copied.characters, privacy: .public) characters")
            } else {
                menuBarLog.error("menu: the pasteboard refused the \(line.rawValue, privacy: .public) error row's \(copied.characters, privacy: .public) characters")
            }
        }
    }
}

/// A bundle built without the model it is supposed to carry.
///
/// [LAW:no-silent-failure] Not a state this app recovers from and not one it downloads its
/// way out of: the model is put in at build time, so a bundle without one was built wrong
/// and the only thing to do about it is say so where the person running it will read it.
struct BundleCarriesNoModel: Error, CustomStringConvertible {
    var description: String {
        "this build carries no model in Contents/Resources/\(ModelStore.carriedResourceName); "
            + "it was built without one. Build it with `make app`, which puts the model in"
    }
}
