import Bench
import Dictation
import GrammaticalNumber
import Grants
import Identity
import InputSource
import Insertion
import LoopLifecycle
import LowTalkerCore
import Onboarding
import Serve
import Uptime

/// The app, assembled from its ports: the loading model, the config and its saves, the loop from
/// a press to the words at a cursor, the input method it types through, and the quit that lets a
/// press's words land. The one composition root: the app hands it the real adapters and a test the
/// one fake of each, and both drive it the same way. Whatever AppKit hands the app delegate is
/// forwarded here; whatever is drawn is read from here. [LAW:decomposition]
/// [LAW:effects-at-boundaries]
@MainActor
public final class LowTalkerApp {
    private let ports: Ports

    public init(ports: Ports) {
        self.ports = ports
        launched = ports.clock.now
        engineReadiness = .preparing(nil, since: launched)
        inputMethodWatch = InputMethodWatch(app: ports.build)
    }

    /// When the app began, which every readout of the engine's wait counts from.
    private let launched: HostTime

    // MARK: - what the status item, the menu and the word box read

    /// What the engine is doing. The status icon's face too, since a first load runs for minutes
    /// and an icon that looks ready through them reads as an app that is not answering.
    public private(set) var engineReadiness: EngineReadiness
    /// The engine's readiness in words, read now on the app's clock.
    public var engineReadout: String { engineReadiness.readout(at: ports.clock.now) }
    /// What the menu says after "Hotkey: ".
    public private(set) var hotkeyStatus: HotkeyStatus = .starting(step: nil)
    /// What the loop is doing with presses, which the icon shows over the engine's readiness.
    public private(set) var activity: Dictation.Activity = .idle
    /// Why the last press's words reached no cursor, while no press has begun since.
    public private(set) var lastFailure: String?

    /// The config this app runs on, read once at launch and again at every save: what the
    /// microphone does at rest, the modes the hotkey listens for and where the server listens,
    /// from one reading, so none of them comes from a different version of the file. Only
    /// `follow` changes it once it is read. [LAW:one-source-of-truth]
    ///
    /// Nil until `reading` ends: the file is read only once each carried model's tokenizer can
    /// check every mode's vocabulary, and everything that runs on the config awaits that reading.
    public private(set) var running: RunningConfig?
    private var config: Result<Config, ConfigError>? { running?.config }

    /// What the microphone is doing.
    public var microphone: AudioCapture.Doing { capture.doing }
    /// The transcription server's switch, in a build that can serve.
    public var serving: ServerSwitch? { ports.server }
    /// Whether a quit has been asked for.
    public var quitting: Bool { lifecycle.quitting }

    /// The words no cursor took, for the life of the app and past it: a loop rebuilt over a new
    /// config keeps offering them, and so does the next launch.
    public private(set) lazy var hold: Hold = Hold(store: ports.held, failedToKeep: { [unowned self] unkept in
        ports.told(.heldUnkept(unkept))
    }) { [unowned self] state in
        showBox(held: state.held)
        ports.told(.held(state))
    }

    /// Speech no engine heard, for the life of the app and past it: a press the model failed to
    /// load under keeps its audio here, and it is read into held words once a model has loaded, in
    /// this launch or the next.
    public private(set) lazy var keptSpeech = Recovery(store: ports.unheard, hold: hold, sessions: loopTurn, clock: ports.clock)

    /// Whose decode the engine runs next: every press holds it from key-down, so a served caller
    /// and a bench run wait for the speaker. Made with the app rather than with the engine, so a
    /// press that begins while the model still loads is already holding it when the server's first
    /// caller arrives. [LAW:single-enforcer]
    private let turns = EngineTurns()

    /// The one bench run at a time, which the first press heard during it stops. It holds the
    /// app's turns for a run, so a served request waits for it as for a press.
    public private(set) lazy var benchRuns = BenchRuns(turns: turns)

    /// The chords the config listens for, in the words a person presses them by.
    public var chordName: String {
        switch config {
        case .success(let config)?: Hotkey.named(in: config)
        // The status line already says why nothing is heard.
        case .failure?: "no chord: the config cannot be read"
        case nil: preconditionFailure("only a loop `adopt` built says how to press, and it adopts only a config that was read")
        }
    }

    // MARK: - launch and quit

    /// Shows what the last run held and starts everything that runs from launch: the model's
    /// load, the server the person last chose, the loop as far as what is granted allows, and the
    /// following of the config's saves.
    public func launch() {
        show(engineReadiness)
        // Before the engine, so speech kept by an earlier run is found at launch and the first
        // load that lands has it to read. [LAW:no-ambient-temporal-coupling]
        _ = keptSpeech
        _ = engine
        // What the last run held is shown from launch, not from the first loop, which waits on
        // the microphone grant. [LAW:nothing-unseen] So is a store that could not be read.
        hold.unrestored.map { ports.told(.heldUnrestored($0)) }
        // Listening from launch when the person last chose to, answering 503 until the model is
        // resident, so a client started beside the app is told to wait rather than refused. Its
        // binding, like the come-up's first step, awaits the config's reading, so both start now.
        ports.server?.resume(at: serveBinding)
        showHotkeyStatus(.starting(step: nil))
        // A launch asks for no grant. Every grant is asked for from its own step in setup, after
        // that step has said why; see `ask(_:)`.
        lifecycle.comeUp()
        // Once the config is read, each save is a reload of the config the server and the loop
        // started on.
        reloading = Task {
            let prompts = await prompting.value
            let read = await reading.value
            guard !Task.isCancelled else { return }
            for await next in ports.config.reloads(after: read, prompting: prompts) { follow(next) }
        }
    }

    /// Refuses anything new at once, then waits out the sessions: a press heard just before the
    /// quit still has its words on the way to the cursor, and the wait is what lets them land.
    /// The quit is granted once the task this returns ends. [LAW:no-ambient-temporal-coupling]
    /// The quit has an owner, rather than a race.
    public func quit() -> Task<Void, Never> {
        let rebuilding = lifecycle.quit()
        // A save during the drain would rebind the server and move the microphone under it.
        reloading?.cancel()
        return Task {
            // A rebuild in progress is let finish first, so the loop waited on is the last one.
            await rebuilding?.value
            // The hotkey comes down before the wait, as at every other teardown: a press open
            // when the quit arrives is ended as lapsed and reported, rather than the app going
            // mid-utterance leaving nothing behind to say it did, and no key-down arriving during
            // the wait can open a session there is no longer anyone to close.
            await listening?.stop()
            // Every session's audio ended at its key-up and no key-down can open another, so the
            // microphone goes now: a resting mode that holds it open does not hold it through a
            // drain that can wait minutes on a cold load.
            capture.stop()
            // A refused wait is reported and the quit still granted: an app that cannot be quit
            // would be the worse failure of the two. [LAW:no-silent-failure]
            do throws(SerialQueueError) { try await listening?.dictation.finish() } catch { reportFailure(Dictation.Failed(error)) }
        }
    }

    // MARK: - the readings every surface draws from

    /// What this installation's setup needs, read off this Mac now.
    ///
    /// The one reading the menu, the guided setup, and the question of whether setup has
    /// anything to show all draw from. Paid on every read rather than kept warm because a cached
    /// reading is one that can be stale exactly when it matters: right after the person gave the
    /// grant the menu was telling them to give. [LAW:no-ambient-temporal-coupling]
    public func readiness() -> Readiness {
        let readiness = OnboardingProbe.readiness(microphone: readMicrophone(), inputMethodSwitchedOn: ports.inputMethod.isSwitchedOn)
        ports.told(.onboarding(readiness))
        return readiness
    }

    /// Takes up a reading of the requirements: the loop comes up or is rebuilt when it should.
    public func settle(_ readiness: Readiness) {
        lifecycle.settle(requirementsMet: readiness.ready)
    }

    /// The app's microphone authorization as it stands now.
    private func readMicrophone() -> MicrophoneAuthorization {
        let microphone = MicrophonePermission(authority: ports.microphone).current
        ports.told(.privacy(microphone))
        return microphone
    }

    // MARK: - what a person asks for

    /// Asks macOS for one requirement - the only place in the app that does, and reached only
    /// from the button a person pressed on that requirement's step. Each case raises at most one
    /// system dialog.
    ///
    /// Answers with how the request ended, and what went wrong for the step to show when
    /// something did. A person declining is not something that went wrong: the next reading shows
    /// the step still unmet, with what skipping it costs. [LAW:no-silent-failure]
    public func ask(_ row: Requirement.Row) async -> SetUpRequest {
        switch row {
        case .microphone:
            // macOS asks about the microphone once. Past that, requesting answers at once and
            // shows nothing, so a decided "no" is said here and the pane opened instead.
            switch readMicrophone() {
            case .withheld(.notDetermined):
                // Asked here, as measured on studious 2026-09-24: one dialog, naming the app.
                _ = await MicrophonePermission(authority: ports.microphone).request()
                return .answered
            case .withheld(.denied):
                return .sentToSystemSettings("macOS asks only once. Turn on \(AppIdentity.displayName) in the \(row.rawValue) list in System Settings.")
            case .withheld(.restricted):
                return .failed("A policy on this Mac blocks the microphone.")
            case .granted:
                return .made
            }
        case .inputMethod:
            do { try await ports.inputMethod.switchOn() } catch { return .failed("\(error)") }
            // Switched on is not selected: once it reads as met, the loop is rebuilt so the
            // install selects it, whether or not the loop is up.
            lifecycle.inputMethodWasSwitchedOn()
            return .made
        }
    }

    /// The word box's circle: puts the box away, cancelling the press it showed.
    public func dismissBox() {
        box.dismiss(cancelling: listening?.steering, hold: hold)
    }

    /// The word box's Insert: the held words, through the loop listening.
    public func insertHeld() {
        // [LAW:nothing-unseen] A click with no loop to insert through places nothing, and says so.
        ports.told(.box(.askedToInsert(words: hold.held?.allWords.words.count ?? 0, listening: listening != nil)))
        listening?.dictation.insertHeld()
    }

    /// The word box's Copy: the held words to the pasteboard. A click is the person asking for
    /// the copy, so replacing what the pasteboard held is what they asked for.
    public func copyHeld() {
        guard let text = hold.held?.clipboardText else { return ports.told(.box(.nothingToCopy)) }
        guard ports.pasteboard(text) else { return ports.told(.box(.copyRefused(characters: text.count))) }
        ports.told(.box(.copied(characters: text.count)))
        // The words are the person's to paste now. Held, the next press would type them ahead of
        // its own, beside the paste; dismissed, the box closes and the menu brings them back.
        hold.dismiss()
    }

    /// The menu's one step back from a click on the box's circle.
    public func bringBackDismissed() {
        // [LAW:nothing-unseen] A click with no loop to bring them back through moves nothing, and says so.
        ports.told(.box(.askedToBringBack(words: hold.dismissed?.allWords.words.count ?? 0, listening: listening != nil)))
        // The box opens again when the loop holds the words again.
        listening?.dictation.bringBackDismissed()
    }

    public func discardKeptSpeech() {
        keptSpeech.discard()
    }

    /// Only in a build that has a server to switch.
    public func toggleServing() {
        ports.server.map { $0.choose(!$0.chosen, at: serveBinding) }
    }

    // MARK: - what is shown

    /// [LAW:one-source-of-truth] Every engine status passes through here, so the menu and the
    /// log never tell different stories.
    private func show(_ readiness: EngineReadiness) {
        let box = activity.box(over: engineReadiness)
        engineReadiness = readiness
        // Only a change in what the box shows redraws it, so the load's phases leave it be.
        if activity.box(over: readiness) != box { showBox(held: hold.held) }
        ports.told(.engine(readiness, at: ports.clock.now))
    }

    private func show(_ activity: Dictation.Activity) {
        self.activity = activity
        showBox(held: hold.held)
        ports.told(.activity(activity))
    }

    private func showHotkeyStatus(_ status: HotkeyStatus) {
        hotkeyStatus = status
        showBox(held: hold.held)
        ports.told(.hotkey(status))
    }

    /// When the word box is shown, what it shows, and its dismissal.
    private lazy var box = WordBox(panel: ports.panel)

    /// [LAW:one-source-of-truth] The box, drawn from the loop's activity, what is held, and
    /// whether the hotkey is listening, as the menu says, to insert it. `held` is passed by the
    /// hold as it changes, since the hold calls here before it is assigned.
    private func showBox(held: Held?) {
        box.show(activity, over: engineReadiness, held: held, insertable: hotkeyStatus.isListening)
    }

    // MARK: - the engine

    /// The engine, from the moment launch starts loading it, as each press finds it at key-down:
    /// waited for while it loads, and loaded again by the first press after a load that failed.
    ///
    /// [LAW:no-ambient-temporal-coupling] Nothing can call the transcriber before it is resident:
    /// the only handle is the supply's task, which yields the value only when the load has
    /// returned. Lazy so that it can name `loadEngine`; touching it is what starts the load.
    private lazy var engine = supplyEngine()

    /// Which supply is the app's: each one counts up from the last, and only the current one's
    /// load may say what the engine is. [LAW:one-source-of-truth]
    private var engineGeneration = 0

    /// A supply whose loads take the model the running config names: at launch, and again when a
    /// save names another model. A load from a supply since replaced lands nowhere, so a slow
    /// load of the old model never takes the menu, the server or kept speech from the new one.
    /// [LAW:no-ambient-temporal-coupling]
    private func supplyEngine() -> EngineSupply {
        engineGeneration += 1
        let generation = engineGeneration
        return EngineSupply { [unowned self] attempt in try await loadEngine(attempt: attempt, generation: generation) }
    }

    private func loadEngine(attempt: Int, generation: Int) async throws -> any Transcriber {
        // The first attempt's wait counts from launch, and a later one's from the press that
        // started it.
        let since = attempt == 1 && generation == 1 ? launched : ports.clock.now
        let current = { @MainActor [unowned self] in generation == engineGeneration }
        show(.preparing(nil, since: since))
        ports.server?.answer(with: .loading)
        do {
            // The model is the config's, so the load waits on its reading; a config that was
            // refused fails the load with the refusal, said where a failed load is said.
            let model = try await readConfig().model
            let loaded = try await ports.model.load(model, turns: turns) { phase in
                Task { @MainActor in
                    let next = self.engineReadiness.reporting(phase)
                    if current(), next != self.engineReadiness { self.show(next) }
                }
            }
            if current() {
                show(.ready(loaded.model, after: since.duration(to: ports.clock.now)))
                ports.server?.answer(with: .ready(loaded.served))
                // Reads the speech kept while no engine could hear it, as a served caller: its
                // passes wait while a press holds the engine. Starts a task and returns, so this
                // load never waits on a decode that waits on the press that waits on this load.
                keptSpeech.landed(loaded.served)
            } else {
                ports.told(.engineReplaced(.success(loaded.model)))
            }
            return loaded.dictation
        } catch {
            // [LAW:no-silent-failure] A model that failed to load is the one thing the menu must
            // say, since every press after this would otherwise fail with no explanation on screen.
            if current() {
                show(.failed("\(error)"))
                ports.server?.answer(with: .failed("the model failed to load: \(error)"))
            } else {
                ports.told(.engineReplaced(.failure(error)))
            }
            throw error
        }
    }

    // MARK: - the config

    /// Each carried model's tokenizer alone, loaded from launch: a fraction of a second, where the
    /// model it belongs to can take minutes.
    private lazy var prompting: Task<Prompting, Never> = Task { @MainActor in
        let loading = ports.clock.now
        let prompts = await ports.model.prompting()
        // [LAW:nothing-unseen] The reading of the config waits on this, so it is told.
        ports.told(.prompts(Prompting.Load(after: loading.duration(to: ports.clock.now), prompting: prompts)))
        return prompts
    }

    /// The config's reading at launch, through the tokenizers, so a mode the model it names could
    /// not be told is refused as the file is read. A model whose tokenizer did not load refuses
    /// the config that names it, in its own words, and the file is never run on unchecked.
    /// [LAW:no-silent-failure]
    private lazy var reading: Task<RunningConfig, Never> = Task { @MainActor in
        let read = RunningConfig(reading: ports.config.read(prompting: await prompting.value))
        running = read
        ports.told(.config(read))
        return read
    }

    /// The config as it stands once the launch reading has ended. Awaited, never assumed: a
    /// come-up the menu or the setup starts at launch, and a server switched on then, wait here
    /// for the reading. [LAW:no-ambient-temporal-coupling] What they then run on is the config as
    /// it stands, which a save may have moved past the launch reading.
    private func readConfig() async throws -> Config {
        _ = await reading.value
        guard let config else { preconditionFailure("the launch reading sets the running config before it ends") }
        return try config.get()
    }

    /// Where the server listens, from `readConfig`, so a tokenizer that did not load stops a
    /// chosen server with that reason rather than leaving it off. [LAW:no-silent-failure]
    private func serveBinding() async throws -> ServeBinding {
        try await readConfig().serve
    }

    /// The task following the config's saves, ended by a quit.
    private var reloading: Task<Void, Never>?

    /// Takes up a save of the config: each setting whose value changed is moved to the new value,
    /// and the rest are left alone. A save the file refused leaves every one where it was, and the
    /// menu says why. [LAW:no-silent-failure]
    ///
    /// Nothing here ends a press. A mode moved mid-hold leaves the hold to end at its own chord's
    /// release, heard in the mode it began in, and a resting mode moved mid-hold is taken up at
    /// the key-up.
    private func follow(_ next: RunningConfig) {
        let was = try? config?.get()
        running = next
        // No config ran before this reading: the loop was held down for want of one, and comes up
        // the way it does at launch, whose status line says what still stops it - this reading's
        // refusal among them. A refusal with a config running before it reads as that config,
        // `.kept`, so it arrives below and moves nothing.
        guard let was, case .success(let now) = next.config else {
            // The load before this reading failed for want of a config; this one's model loads.
            if case .success = next.config { engine = supplyEngine() }
            ports.told(.config(next))
            ports.server?.resume(at: serveBinding)
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
                if hotkeyStatus.isListening { showHotkeyStatus(.listening(listeningStatus)) }
                return "modes \(now.modes)"
            case .microphone:
                // What the move comes to is its own report, once it lands.
                capture.rest(as: now.microphone)
                return "microphone \(capture.doing)"
            case .serve:
                ports.server?.resume(at: serveBinding)
                return "server binding"
            case .model:
                // The next press waits for the new model; a press in flight finishes on the one
                // it took.
                engine = supplyEngine()
                return "model \(now.model)"
            }
        }
        ports.told(.configMoved(next, moved: moved))
    }

    // MARK: - the loop

    /// Every device report the microphone answers and every move of its resting mode, and what it
    /// is doing after. [LAW:nothing-unseen]
    private lazy var capture: AudioCapture = AudioCapture(hardware: ports.audio, startingAt: launched) { [unowned self] report in
        ports.told(.microphone(report, doing: capture.doing))
    }

    /// The loop's one turn: every insert, offer and bring-back runs on it, and so does the hand-off
    /// of words read from kept speech to `hold`. For the life of the app, so every loop `adopt`
    /// rebuilds takes the same one. [LAW:single-enforcer]
    private let loopTurn = SerialQueue()

    /// The input method's process, the one source of what the status line says of it.
    /// [LAW:one-source-of-truth]
    private var inputMethodWatch: InputMethodWatch

    /// The loop that is listening now.
    private struct Listening {
        let hotkey: Hotkey
        let dictation: Dictation
        let steering: KeySteering
        /// How the input method's notices stop, hosted for as long as the hotkey is up. Nil when
        /// they or the hotkey could not come up, and then neither is.
        let notices: Disposal?

        /// [LAW:single-enforcer] Every teardown, in one order: the hotkey comes down and what it
        /// handed the main queue is delivered, then the notices stop, so the port's name is free
        /// for the loop built next.
        @MainActor func stop() async {
            await hotkey.stopAndDeliver()
            notices?()
        }
    }

    private var listening: Listening?

    /// When the loop comes up, is rebuilt, or is left as it stands, and the one owner of the
    /// quit's refusal of anything new. [LAW:single-enforcer]
    private lazy var lifecycle = LoopLifecycle(
        startCapture: { [unowned self] in await startCapture() },
        adopt: { [unowned self] in await adopt() },
        requirementsMet: { [unowned self] in readiness().ready },
        watching: { [unowned self] in listening?.hotkey.isWatching == true },
        // A requirement left unmet shows the guided setup, so a person sees why nothing is heard.
        offerSetUp: { [unowned self] in if !readiness().unmet.isEmpty { ports.showSetUp() } },
        told: { [unowned self] in ports.told(.lifecycle($0)) })

    /// The come-up's first step: the config and the microphone grant read, then capture holding
    /// the microphone. Answers what came of it; `lifecycle` builds the loop over it, last, so no
    /// press can arrive before there is a capture to open a microphone for it.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// Reads the grant and asks for none: a microphone not yet allowed leaves the loop down with
    /// the reason on the status line, and the setup's step is where it is asked for.
    ///
    /// A config that cannot be read stops the app listening rather than being answered with the
    /// defaults, which is `ConfigError`'s own rule: "there is no config" and "there is a config I
    /// could not read" are different facts. [LAW:no-silent-failure]
    private func startCapture() async -> LoopLifecycle.Capture {
        do {
            // A capture already running is left running: the microphone was held before, and what
            // came up short was the hotkey or the input method, which the rebuild redoes.
            guard capture.atRest == nil else { return .running }
            // Read before the grant, so a tokenizer that did not load is the status line's reason
            // even while the microphone waits on setup, whose list says that too.
            let atRest = try await readConfig().microphone
            let grant = try readMicrophone().grant()
            // Awaited, so the menu and the readings queued behind the come-up run while a slow
            // input is reached.
            try await capture.start(grant, atRest: atRest)
            return .started
        } catch {
            // Stopping is idempotent, so a grant withheld and a capture that failed to start leave
            // by one path. [LAW:dataflow-not-control-flow]
            capture.stop()
            // A microphone macOS was never asked about, or was told no, is a step in setup, and
            // the status says where it is the way the input method's refusal does.
            let whereToAllow = switch error {
            case MicrophoneAuthorization.Withheld.notDetermined, MicrophoneAuthorization.Withheld.denied:
                "; allow it in \(GuidedSetup.title) in this menu"
            default: ""
            }
            showHotkeyStatus(.off("\(error)\(whereToAllow)"))
            return .notStarted
        }
    }

    /// Takes the loop down and builds it again: the old loop's hotkey comes down first, ending any
    /// press it had open, its sessions are waited out, and then the input method is selected and
    /// the hotkey goes up in front of a new loop. `lifecycle` decides when.
    private func adopt() async {
        if let previous = listening {
            listening = nil
            await previous.stop()
            // A refused wait is reported and the rebuild still made: a loop that cannot be
            // replaced would be the worse failure of the two. [LAW:no-silent-failure]
            do throws(SerialQueueError) { try await previous.dictation.finish() } catch { reportFailure(Dictation.Failed(error)) }
        }
        // [LAW:no-ambient-temporal-coupling] The input method is made ready before the hotkey goes
        // up, so no press is heard that has nowhere to go yet.
        showHotkeyStatus(.starting(step: "setting up the input method"))
        let selected = await selectInputMethod()
        // A loop is built only over capture holding the microphone, capture starts only over a
        // config that was read, and a save the file refused keeps the one that ran.
        guard case .success(let config)? = config else { preconditionFailure("a loop is adopted only once the config has been read") }
        let hotkey = Hotkey(modes: config.modes, feed: ports.modifiers())
        // The words cross to the input method, which commits them at the cursor through the text
        // input system.
        let inserter = await ports.inserter()
        let dictation = Dictation(
            capture: capture,
            // Asked at key-down, so a press after a failed load is refused before the person
            // speaks into it.
            engine: { [unowned self] () throws(EngineUnavailable) in try engine.forPress() },
            turns: turns,
            // [LAW:one-source-of-truth] A press is timed on the app's one clock, which its key
            // events must be stamped on: a feed on another is a composition built wrong, and
            // `start(feeding:)` traps on it.
            executor: Executor(insertingThrough: inserter, clock: ports.clock),
            hold: hold,
            sessions: loopTurn,
            recovery: keptSpeech,
            report: { [unowned self] in report($0) },
            showing: { [unowned self] in show($0) }
        )
        // How Return and Escape steer this loop's press, the input method's questions and the word
        // box's dismissal alike.
        let steering = KeySteering(dictation: dictation, hotkey: hotkey, holdsReturn: ports.returnHolds, dismissing: { [unowned self] in box.escape(cancelling: $0, hold: hold) })
        // The hotkey goes up only over an input method that was selected: a hotkey over one that
        // refused would open the microphone on every press for words that go nowhere, while the
        // status line said the loop was off. [LAW:no-silent-failure]
        //
        // And only over notices that were hosted. The input method tells each cursor it is given
        // focus in, and the loop listening then offers it what is held. The port's name is one
        // per login session, so a second copy of the app stops here and hears nothing.
        let notices: Result<Disposal, LoopRefusal>
        if case .failure(let refusal) = selected {
            notices = .failure(refusal)
        } else {
            do throws(PortNotHosted) {
                notices = .success(try await ports.notices.host(
                    heard: { [unowned self] notice in
                        inputMethodWatch.heard(notice).map(showInputMethod)
                        if case .cursorArrived = notice { listening?.dictation.cursorArrived() }
                    },
                    // A Return the input method holds asks whether words are owed to it, and
                    // answers to this loop's own press and queue; an Escape asks the word box to
                    // take it, which puts the box away and cancels the press it showed.
                    asked: { steering.answer($0, through: $1) },
                    superviseInputMethod: { [unowned self] in
                        InputMethodSupervisor(clock: ports.clock, open: ports.openInputMethod, told: { [unowned self] in show($0) }).stop
                    }))
            } catch { notices = .failure(LoopRefusal(stringLiteral: "\(error)")) }
        }
        // Notices whose hotkey did not go up are stopped with it, so their supervision says
        // nothing that would put a listening line over the refusal.
        let hearing = notices.flatMap { stop in
            Result {
                // A blocked chord is no press, so the last press's failure stands.
                try hotkey.start(feeding: dictation) { [unowned self] in lastFailure = nil }
                return stop
            }.mapError { error in
                stop()
                return LoopRefusal(stringLiteral: "\(error)")
            }
        }
        listening = Listening(hotkey: hotkey, dictation: dictation, steering: steering, notices: try? hearing.get())
        // A hotkey that went up says how to press it once the input method's process is running,
        // which is that process's event to tell; see `show(_:)`.
        if case .failure(let refusal) = hearing { showHotkeyStatus(.off(refusal.reason)) }
    }

    /// This installation's input method, as its package installed it, registered and - once a
    /// person has switched it on in setup - selected: what the words are committed through. Run at
    /// every rebuild, which is what keeps the input method selected.
    ///
    /// Nothing here puts a system dialog on screen, because a rebuild runs at launch. The input
    /// method is switched on from its own step in setup; see `ask(_:)`.
    ///
    /// [LAW:no-silent-failure] A select that fails leaves a hotkey that would hear every press and
    /// insert nothing, so it comes back as a refusal for the status line.
    private func selectInputMethod() async -> Result<Void, LoopRefusal> {
        do {
            let bundle = try ports.inputMethod.bundle()
            let state = try await ports.inputMethod.select()
            ports.told(.inputMethodSelected(state, bundle: bundle.path))
            // Stopped short of selected only where a person has yet to switch it on, which is a
            // step in setup rather than something that went wrong.
            return state.ready ? .success(()) : .failure("""
                the input method is \(state); switch it on in \(GuidedSetup.title) \
                in this menu, where macOS asks you to allow it
                """)
        } catch {
            ports.told(.inputMethodNotSelected(String(describing: error)))
            return .failure("the input method could not be selected: \(error)")
        }
    }

    /// The input method's process as the notices keep it.
    private func show(_ event: InputMethodSupervisor.Event) {
        ports.told(.supervisor(event))
        showInputMethod(inputMethodWatch.told(event))
    }

    /// The line says how to press only while an input method is running to type the words, of
    /// whatever build. `InputMethodWatch` decides when the line is written and when the log hears it.
    private func showInputMethod(_ showing: InputMethodWatch.Showing) {
        if showing.isNew { ports.told(.inputMethod(showing.standing)) }
        let status: HotkeyStatus = switch showing.standing {
        case .running: .listening(listeningStatus)
        case .ended: .off("the input method ended; \(AppIdentity.displayName) is starting it again")
        case .overMemoryCeiling(_, let overrun):
            .off("the input method is ending itself, \(overrun); \(AppIdentity.displayName) will start it again")
        case .notOpened(let reason):
            .off("the input method could not be started: \(reason); trying again every \(InputMethodSupervisor.throttleInterval.formatted(.units(width: .wide)))")
        }
        showHotkeyStatus(status)
    }

    /// The status line of a hotkey that is listening, and the input method that last ended itself
    /// over its memory ceiling, which the person would otherwise never see (IMK rule 7).
    private var listeningStatus: String {
        "hold \(chordName), or tap it to start and again to stop"
            + (inputMethodWatch.lastOverrun.map { "; the input method ended itself \($0), and was started again" } ?? "")
    }

    // MARK: - what came of each press

    /// One record for each press, however it came out.
    private func report(_ press: Dictation.Report) {
        // [LAW:no-silent-failure] The words went nowhere, or only some of them did, so the menu
        // says why.
        if case .failed(let failed) = press.outcome { lastFailure = failureLine(failed.failure) }
        ports.told(.press(press))
    }

    /// A failure that was no press: the loop's sessions could not be waited out.
    private func reportFailure(_ failed: Dictation.Failed) {
        lastFailure = failureLine(failed.failure)
        ports.told(.loopFailed(failed))
    }
}
