import AppKit
import Bench
import Dictation
import GrammaticalNumber
import Identity
import Grants
import InputSource
import Insertion
import LowTalkerApp
import LowTalkerCore
import MenuBarPresence
import Onboarding
import ServiceManagement
import Serve
import Signals
import StatusMenu
import os

/// The menu-bar agent. `LSUIElement` keeps it out of the Dock, so the status item is the app's
/// only surface; the delegate exists to assemble the app from the real adapters, to install the
/// status item and the windows, and to forward what AppKit hands it. Every decision of the app's
/// is `LowTalkerApp`'s, where a test reaches it.
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

    /// The store the bundle carries, read once, so the engine and the bench read one carried
    /// model. [LAW:one-source-of-truth]
    private let carried = ModelStore.carried(by: .main)

    /// This installation's input method, which the app selects through and the menu reads.
    private let installedInputMethod = InstalledInputMethod()

    /// The app, assembled from the real adapters.
    private lazy var app: LowTalkerApp = assemble()

    /// [LAW:single-enforcer] The one place a real adapter is made: everything the app does, it does
    /// through these.
    private func assemble() -> LowTalkerApp {
        LowTalkerApp(ports: LowTalkerApp.Ports(
            clock: .system,
            // The app's build, read off its bundle at launch, so it is the build that is running and
            // not one an install has since put on disk. The build refuses to make a bundle without it,
            // so its absence is a bundle this project did not make.
            build: Build(of: .main) ?? { preconditionFailure("the app bundle carries no build number or source revision; it was not built by `make app`") }(),
            microphone: SystemMicrophoneAuthority(),
            audio: SystemAudioHardware(),
            modifiers: { ModifierMonitor() },
            model: CarriedModel(store: carried),
            config: ConfigFileSource(),
            inputMethod: installedInputMethod,
            // Awaited because the inserter reads this process's own signature off the main actor to
            // know who may answer; see `signedLikeThisProcess`.
            inserter: { await InputMethodInserter() },
            notices: InputMethodNotices.Host(),
            openInputMethod: { [installedInputMethod] in try await .open(installedInputMethod.bundle()) },
            held: HeldFile.app,
            unheard: UnheardFiles.app,
            // Nil in the offline build, which cannot accept a connection and so shows nothing about
            // serving.
            server: ServerSwitch.ifEntitled(),
            returnHolds: { ReturnHoldSetting.isOn },
            // NSPasteboard writes only after a clear.
            pasteboard: { text in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            },
            panel: hud,
            showSetUp: { [unowned self] in setUp.show() },
            told: { [unowned self] in record($0) }))
    }

    /// The word box on screen, its buttons the app's.
    private lazy var hud: HUD = HUD(
        circleClicked: { [unowned self] in app.dismissBox() },
        insert: { [unowned self] in app.insertHeld() },
        copy: { [unowned self] in app.copyHeld() })

    /// What the app does, in the unified log, where `log show` can time it: a menu nobody has
    /// open is no way to measure a launch, and no way for an agent to check what the app is
    /// showing without a screen. [LAW:verifiable-goals]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "engine")

    /// [LAW:one-source-of-truth] Every record of the app's lands here: in the log, as the lines
    /// it renders to, and on the status icon when it is a change the icon is drawn from.
    private func record(_ event: LowTalkerApp.Event) {
        for line in event.lines {
            let level: OSLogType = switch line.level {
            case .info: .info
            case .notice: .default
            case .error: .error
            case .fault: .fault
            }
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: line.category.rawValue)
            // Only dictated words go private: a private argument is redacted whatever it holds,
            // an empty one too, and a line with none must read whole in `log show`.
            switch line.dictated {
            case nil: logger.log(level: level, "\(line.text, privacy: .public)")
            case let dictated?: logger.log(level: level, "\(line.text, privacy: .public)\(dictated, privacy: .private)")
            }
        }
        switch event {
        case .engine, .activity: drawStatusIcon()
        default: break
        }
    }

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

    private func drawStatusIcon() {
        // Named, so the icon can be found by a reader with VoiceOver and by an agent
        // reading the bar over Accessibility.
        let description = app.activity.iconDescription(for: AppIdentity.displayName, over: app.engineReadiness)
        switch app.activity.glyph(over: app.engineReadiness) {
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

    /// Flips whether a Return is held until the dictated words land, from the menu's checkbox. The
    /// input method asks for it at each Return, so a change here needs no word to the input method.
    @objc private func toggleReturnHold() {
        ReturnHoldSetting.set(!ReturnHoldSetting.isOn)
    }

    // MARK: - the guided setup

    /// The guided setup, over the one list the menu reads.
    private lazy var setUp = SetUpWindow(
        read: { [unowned self] in app.readiness() },
        ask: { [unowned self] in await app.ask($0) },
        settle: { [unowned self] in app.settle($0) }, log: log)

    @objc private func toggleServing() {
        app.toggleServing()
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

    private lazy var bench = BenchWindow(runs: app.benchRuns, carried: carried)

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
        guard !app.quitting else {
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
        statusItem.isVisible = true
        drawStatusIcon()
        watchStatusItem()
        app.launch()
    }

    /// The quit is the app's: it refuses anything new at once and is granted once the press's
    /// words have landed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let drained = app.quit()
        Task {
            await drained.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - the menu

    /// Why the words of a press would be held rather than typed right now, read at the moment
    /// the menu opens: the input method types only while its source is the one in use. Empty while
    /// it is. The chord is heard either way.
    ///
    /// [LAW:no-silent-failure] A hotkey line that read as working while nothing could type
    /// would send the person after a broken app rather than the Input menu.
    private func untypedBecause() -> [String] {
        let found = installedInputMethod.isSelected ? [] : ["\(AppIdentity.displayName) is not the selected input source"]
        log.notice("hotkey: words held, not typed, because [\(found.joined(separator: "; "), privacy: .public)]")
        return found
    }

    /// What macOS also does with the Fn key when a chord the config listens for holds it, read
    /// at the moment the menu opens, so a setting changed in System Settings shows the next
    /// time it does. Nil when no chord holds Fn or the Globe key does nothing.
    private func globeKeyClash() -> String? {
        let stored = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        let action = GlobeKeyAction(appleFnUsageType: stored)
        let clash: String? = switch app.running?.config {
        case .success(let config)?: action.clash(with: config.modes.chords)
        // The status line already says why no chord is heard.
        case .failure?, nil: nil
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
        let readiness = app.readiness()
        app.settle(readiness)

        // What the user's microphone is doing, on the surface the epic exists for: the
        // menu-bar indicator says the device is open and only this says why, so a lit
        // microphone on an idle Mac is either explained here or is a bug - and a dark one
        // the config asked to hold open says so here too. [LAW:no-silent-failure]
        let microphone = app.microphone
        log.notice("microphone at rest: \(microphone, privacy: .public)")
        let untyped = untypedBecause()
        let globeKey = globeKeyClash()
        let openAtLogin = loginItem.current
        loginLog.notice("open at login: \(openAtLogin, privacy: .public)")
        let engineReadiness = app.engineReadiness
        let hotkeyStatus = app.hotkeyStatus
        let hold = app.hold
        let keptSpeech = app.keptSpeech

        menu.removeAllItems()
        let model = "Model: \(app.engineReadout)"
        let modelRow = if case .failed = engineReadiness { errorRow(model, .model) } else { readout(model) }
        menu.addItem(modelRow)
        // A press made during the wait is not lost, and nothing else on screen says so.
        if case .preparing = engineReadiness { menu.addItem(readout("A press now is heard once the model is ready")) }
        // Beside the model it answers with. [LAW:dataflow-not-control-flow] The offline build
        // has no switch, so no line.
        app.serving.map { serving in
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
        app.lastFailure.map { menu.addItem(errorRow($0, .lastDictation)) }
        // What keeping the held words for the next launch failed at: a fact about the store,
        // not the words, and one the panel has nothing to show for when nothing is held.
        // [LAW:no-silent-failure]
        for trouble in [hold.unrestored?.description, hold.unkept?.description].compactMap({ $0 }) {
            menu.addItem(errorRow("Held words: \(trouble)", .heldWords))
        }
        // The one step back from a click on the panel's circle.
        if let dismissed = hold.dismissed {
            menu.addItem(withTitle: "Bring Back Dismissed Words (\(dismissed.allWords.words.count))", action: #selector(bringBackDismissed), keyEquivalent: "")
        }
        // Speech a press said before the model had loaded, which is audio until an engine reads it:
        // how much, why it is not yet words, and the person's one discard of it. [LAW:nothing-unseen]
        for line in keptSpeech.lines { menu.addItem(errorRow(line, .keptSpeech)) }
        if !keptSpeech.kept.isEmpty {
            menu.addItem(withTitle: "Discard Kept Speech (\(keptSpeech.keptSeconds) s)", action: #selector(discardKeptSpeech), keyEquivalent: "")
        }
        if let running = app.running, running.refusal != nil { menu.addItem(errorRow("Config: \(running)", .config)) }
        if app.benchRuns.isRunning { menu.addItem(readout("A benchmark is running: the next press heard stops it")) }
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
        // Off by default. On, a Return typed while dictating is sent after the dictated words, so
        // the message goes out with them in it; the input method holds a Return only when this is on.
        let holdItem = menu.addItem(withTitle: "Hold Return for Dictated Words", action: #selector(toggleReturnHold), keyEquivalent: "")
        holdItem.state = ReturnHoldSetting.isOn ? .on : .off
        if let serving = app.serving {
            let item = menu.addItem(withTitle: "Serve Transcription", action: #selector(toggleServing), keyEquivalent: "")
            item.state = serving.chosen ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Acknowledgements", action: #selector(openNotices), keyEquivalent: "")
        menu.addItem(withTitle: "Quit \(AppIdentity.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func discardKeptSpeech() {
        app.discardKeptSpeech()
    }

    @objc private func bringBackDismissed() {
        app.bringBackDismissed()
    }

    /// A line the menu says and nothing a reader can press. An item with no action is
    /// one AppKit disables on its own, which is the whole of what "readout" means here.
    private func readout(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    /// Which of the menu's lines failed, as the log names it when that line is copied.
    private enum FailedLine: String {
        case model, server, microphone, hotkey, lastDictation, heldWords, keptSpeech, config
    }

    /// A line that says what failed, which a click copies whole to the clipboard.
    private func errorRow(_ text: String, _ line: FailedLine) -> NSMenuItem {
        ErrorRow(text, copyingTo: .general) { [menuBarLog] copied in
            // [LAW:nothing-unseen] The count, not the text: a failure line can carry dictated words.
            if copied.taken {
                menuBarLog.notice("menu: copied the \(line.rawValue, privacy: .public) error row, \(counted(copied.characters, "character", "characters"), privacy: .public)")
            } else {
                menuBarLog.error("menu: the pasteboard refused the \(line.rawValue, privacy: .public) error row's \(counted(copied.characters, "character", "characters"), privacy: .public)")
            }
        }
    }
}
