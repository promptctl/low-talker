import AVFoundation
import Dictation
import DictationFakes
import Foundation
import Grants
import GrantsFakes
import Identity
import InputSource
import InputSourceFakes
import Insertion
import InsertionFakes
import LoopLifecycle
import LowTalkerApp
import LowTalkerCore
import LowTalkerCoreFakes
import Onboarding
import Serve
import Synchronization
import TestProbes
import Testing
import Uptime

/// The whole app, assembled from the one fake of each port on one clock the test moves, and
/// driven as AppKit drives it: launched, pressed, saved, rebuilt and quit.
@MainActor
final class AppRig {
    let clock = ManualHostClock(startingAt: HostTime(uptime: .seconds(1000)))
    var now: HostTime { clock.now }
    /// Moved whenever anything the app or a fake does lands, so a test awaits a condition
    /// rather than polling a clock. [LAW:no-ambient-temporal-coupling]
    let changes = Changes()
    let hardware = FakeHardware()
    let authority: FakeMicrophoneAuthority
    let config: FakeConfigFile
    let installation: FakeInputMethodInstallation
    let inputMethod = FakeInputMethod()
    let notices: FakeNoticeHost
    let model: FakeModelSupply
    let held = FakeHeldStore()
    let unheard = FakeUnheardStore()
    let panel = FakePanel()
    /// The keyboard each rebuild's hotkey was handed, in order.
    private(set) var feeds: [FakeModifierFeed] = []
    /// The input method's process, which ends when the test opens this.
    let process = Gate()
    private(set) var events: [LowTalkerApp.Event] = []
    private(set) var setUpShown = 0
    private(set) var pasted: [String] = []
    /// Every binding the server was asked to listen on, in order.
    let bindings = Recorded<ServeBinding>()
    let server: ServerSwitch?
    private let domain: URL?
    private(set) var app: LowTalkerApp!

    init(
        microphone: AVAuthorizationStatus = .authorized,
        config text: String? = nil,
        switchedOn: Bool = true,
        noticesRefused: PortNotHosted? = nil,
        serving: Bool = false,
        heard: String = "hello"
    ) {
        authority = FakeMicrophoneAuthority(status: microphone)
        config = FakeConfigFile(text)
        installation = FakeInputMethodInstallation(switchedOn: switchedOn)
        let changes = changes
        notices = FakeNoticeHost(refusing: noticesRefused, noting: changes)
        model = FakeModelSupply(noting: changes) { turns in FakeTranscriber(turns: turns) { _ in Transcript(typed: heard) } }
        inputMethod.noting(changes)
        if serving {
            let domain = FileManager.default.temporaryDirectory.appendingPathComponent("LowTalkerAppTests-\(UUID().uuidString)")
            let defaults = UserDefaults(suiteName: domain.path)!
            defaults.set(true, forKey: ServerSwitch.choiceKey)
            let bindings = bindings
            let server = ServerSwitch(defaults: defaults) { binding, _ throws(ListenRefused) in
                bindings.append(binding)
                changes.note()
                throw ListenRefused(binding: binding, reason: CocoaError(.featureUnsupported))
            }
            self.server = server
            self.domain = domain
        } else {
            server = nil
            domain = nil
        }
        app = LowTalkerApp(ports: LowTalkerApp.Ports(
            clock: clock.clock,
            build: Build(number: "1", revision: "test"),
            microphone: authority,
            audio: hardware,
            modifiers: { [weak self, clock, changes] in
                let feed = FakeModifierFeed(on: clock.clock)
                feed.noting(changes)
                self?.feeds.append(feed)
                return feed
            },
            model: model,
            config: config,
            inputMethod: installation,
            inserter: { [inputMethod] in inputMethod },
            notices: notices,
            openInputMethod: { [process] in RunningInputMethod(pid: 4242, launched: nil, ended: { await process.wait() }) },
            held: held,
            unheard: unheard,
            server: server,
            returnHolds: { false },
            pasteboard: { [weak self] text in
                self?.pasted.append(text)
                return true
            },
            panel: panel,
            // Weak, because the app's own tasks can outlive the test that made it, and a rig gone
            // has nothing left to record.
            showSetUp: { [weak self] in self?.setUpShown += 1 },
            told: { [weak self, changes] event in
                self?.events.append(event)
                changes.note()
            }))
    }

    deinit {
        domain.map { try? FileManager.default.removeItem(at: $0.appendingPathExtension("plist")) }
    }

    /// Await until `condition` holds, woken as the app's effects land.
    func until(_ condition: () -> Bool) async {
        await changes.settled(condition)
    }

    /// The keyboard the hotkey listening now was handed.
    var feed: FakeModifierFeed { feeds.last! }

    /// What a listening hotkey's status line says, for the config's chords.
    func listening(on chord: String = "Right Option") -> HotkeyStatus {
        .listening("hold \(chord), or tap it to start and again to stop")
    }

    /// The default chord going down or up now, stamped at this moment on the one clock.
    func chord(_ direction: KeyEvent.Direction, _ key: Modifier = .rightOption) {
        feed.type(KeyEvent(key: key, direction: direction, modifiers: direction == .down ? [key] : [], time: now, lastTyped: HostTime(uptime: .zero)))
    }

    /// A second of speech into the microphone open for the press, said from now on.
    func speak() async {
        await until { hardware.engines.contains { !$0.disposed } }
        let said = now
        let samples = [Float](repeating: 0.1, count: 16_000)
        clock.advance(by: .seconds(AudioClip.duration(for: samples.count)))
        hardware.live.appending(samples, said)
    }

    /// The chord down, a second of speech, and the chord up.
    func hold() async {
        chord(.down)
        await speak()
        chord(.up)
    }

    /// Launched, and listening once the input method's process is running.
    func launched() async {
        app.launch()
        await until { app.hotkeyStatus == listening() }
    }

    var lines: [String] { events.flatMap(\.lines).map(\.text) }

    var reports: [Dictation.Report] {
        events.compactMap { if case .press(let report) = $0 { report } else { nil } }
    }

    /// Every press that failed, as it was reported.
    var failures: [Dictation.Failed] {
        reports.compactMap { if case .failed(let failed) = $0.outcome { failed } else { nil } }
    }

    /// Whether the one press that failed was stopped by its hotkey coming down mid-press.
    var aPressLapsed: Bool {
        failures.count == 1 && failures.first?.kind == "PressStopped(PressLapsed)"
    }
}

/// What the server's listen was asked for, across the actor its closure runs on.
final class Recorded<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    var all: [Value] { values.withLock { $0 } }
    func append(_ value: Value) { values.withLock { $0.append(value) } }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LowTalkerAppTests {
    /// Every requirement met: the model loads, the config is read, capture holds the microphone,
    /// the input method is selected and its process running, and a press's words land.
    @Test func aLaunchWithEveryRequirementMetListens() async throws {
        let rig = AppRig()
        await rig.launched()
        #expect(rig.installation.isSelected)
        #expect(rig.notices.isHosted)
        #expect(rig.setUpShown == 0)
        await rig.until { if case .ready = rig.app.engineReadiness { true } else { false } }

        await rig.hold()
        await rig.until { rig.inputMethod.inserted == ["hello"] }
        await rig.until { !rig.reports.isEmpty }
        guard case .session = rig.reports.first?.outcome else {
            Issue.record("the press reported \(String(describing: rig.reports.first?.outcome))")
            return
        }
        #expect(rig.lines.contains("config: running on the file as last saved"))
    }

    /// A microphone macOS was never asked about leaves the hotkey down saying where to allow it,
    /// and the guided setup is shown.
    @Test func aLaunchWithTheMicrophoneWithheldSaysWhereToAllowIt() async {
        let rig = AppRig(microphone: .notDetermined)
        rig.app.launch()
        await rig.until { rig.setUpShown == 1 }
        #expect(rig.app.hotkeyStatus == .off("\(MicrophoneAuthorization.Withheld.notDetermined); allow it in \(GuidedSetup.title) in this menu"))
        #expect(rig.feeds.isEmpty)
    }

    /// An input method a person has not switched on is not selected, and the hotkey stays down
    /// with the step that switches it on.
    @Test func anInputMethodThatWillNotBeSelectedLeavesTheHotkeyDown() async {
        let rig = AppRig(switchedOn: false)
        rig.app.launch()
        await rig.until { rig.setUpShown == 1 }
        #expect(rig.app.hotkeyStatus == .off("the input method is registered, switched off; switch it on in \(GuidedSetup.title) in this menu, where macOS asks you to allow it"))
        #expect(rig.feeds.allSatisfy { $0.installations.isEmpty })
        #expect(!rig.notices.isHosted)
    }

    /// Notices that cannot be hosted, as when another copy of the app hears on the port, leave
    /// the hotkey down with why.
    @Test func noticesThatCannotBeHostedLeaveTheHotkeyDown() async {
        let rig = AppRig(noticesRefused: .nameIsTaken("the notice port"))
        rig.app.launch()
        await rig.until { if case .off = rig.app.hotkeyStatus { true } else { false } }
        #expect(rig.app.hotkeyStatus == .off("\(PortNotHosted.nameIsTaken("the notice port"))"))
        #expect(rig.feeds.allSatisfy { $0.installations.isEmpty })
    }

    /// A save that moves the modes, the microphone's resting mode and the server's binding moves
    /// each of them, and says so.
    @Test func aSaveMovesTheModesTheMicrophoneAndTheServer() async throws {
        let rig = AppRig(serving: true)
        await rig.launched()
        await rig.until { rig.bindings.all == [.loopback] }

        rig.config.save("""
            microphone = { at_rest = "open" }
            [serve]
            interface = "192.168.1.20"
            token = "t"
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["leftControl"] }
            """)
        await rig.until { rig.events.contains { if case .configMoved = $0 { true } else { false } } }
        let moved = rig.events.compactMap { if case .configMoved(_, let moved) = $0 { moved } else { nil } }
        #expect(moved.count == 1)
        #expect(moved.first?.count == 3)
        #expect(rig.app.hotkeyStatus == rig.listening(on: "Left Control"))
        await rig.until { if case .keeping(.open) = rig.app.microphone { true } else { false } }
        let binding = ServeBinding.interface(try InterfaceAddress("192.168.1.20"), token: try BearerToken("t"))
        await rig.until { rig.bindings.all == [.loopback, binding] }

        // The new chord is the one heard.
        rig.chord(.down, .leftControl)
        await rig.speak()
        rig.chord(.up, .leftControl)
        await rig.until { rig.inputMethod.inserted == ["hello"] }
    }

    /// A save the file refuses moves nothing: the chord, the microphone and the server stay as
    /// they were, and the config line says why.
    @Test func aRefusedSaveMovesNothing() async throws {
        let rig = AppRig(serving: true)
        await rig.launched()
        await rig.until { rig.bindings.all == [.loopback] }

        rig.config.save(ConfigSourceContract.notTOML)
        await rig.until { rig.events.contains { if case .configMoved = $0 { true } else { false } } }
        let moved = rig.events.compactMap { if case .configMoved(_, let moved) = $0 { moved } else { nil } }
        #expect(moved == [[]])
        #expect(rig.app.running?.refusal != nil)
        #expect(rig.app.hotkeyStatus == rig.listening())
        #expect(rig.bindings.all == [.loopback])

        await rig.hold()
        await rig.until { rig.inputMethod.inserted == ["hello"] }
    }

    /// A quit asked while a released press's words are on their way to the cursor is granted
    /// only once they have landed.
    @Test func aQuitLetsAPressesWordsLandFirst() async {
        let rig = AppRig()
        await rig.launched()
        rig.inputMethod.hold()
        await rig.hold()
        await rig.until { rig.inputMethod.holding == 1 }

        let quit = rig.app.quit()
        let granted = Flag()
        Task { await quit.value; granted.raise() }
        // The quit takes the hotkey down and stops the notices at once, while the insert still
        // waits. The quit's next step, were it not waiting, would end it in the same main-actor
        // turn as the notices' stop, so one turn after it the grant would already be in.
        await rig.until { !rig.notices.isHosted }
        await Task.yield()
        #expect(!granted.raised)
        #expect(rig.app.quitting)

        rig.inputMethod.letGo()
        await quit.value
        #expect(rig.inputMethod.inserted == ["hello"])
    }

    /// A quit asked while a press is still held ends the press as lapsed, reports it, and keeps
    /// its words for the next launch before the quit is granted.
    @Test func aQuitDuringAPressKeepsItsWordsFirst() async {
        let rig = AppRig()
        await rig.launched()
        rig.chord(.down)
        await rig.speak()

        await rig.app.quit().value
        #expect(rig.aPressLapsed)
        #expect(rig.held.kept?.allWords.text == "hello")
        #expect(rig.inputMethod.inserted.isEmpty)
    }

    /// The input method switched on while a press is open rebuilds the loop: the old hotkey
    /// comes down, the press it had open ends as lapsed and is reported, its words held, and a new
    /// loop comes up that hears the next press.
    @Test func aRebuildDuringAPressEndsItAndBringsUpANewLoop() async {
        let rig = AppRig()
        await rig.launched()
        let first = rig.feed

        rig.chord(.down)
        await rig.speak()
        #expect(await rig.app.ask(.inputMethod) == .made)
        rig.installation.answer(allowing: true)
        rig.app.settle(rig.app.readiness())

        await rig.until { rig.feeds.count == 2 && rig.app.hotkeyStatus == rig.listening() }
        #expect(first.installations.allSatisfy { $0.disposed })
        #expect(rig.feed.installations.contains { !$0.disposed })
        #expect(rig.aPressLapsed)
        #expect(rig.app.lastFailure != nil)
        #expect(rig.app.hold.held?.allWords.text == "hello")
        #expect(rig.events.contains { if case .lifecycle(.settled(.rebuilding)) = $0 { true } else { false } })

        // The new loop hears the next press, which types what is held ahead of its own words.
        await rig.hold()
        await rig.until { rig.app.hold.held == nil && !rig.inputMethod.inserted.isEmpty }
        // One insert, the held words first: the fake's words carry no space of their own.
        #expect(rig.inputMethod.inserted == ["hellohello"])
        #expect(rig.app.lastFailure == nil)
    }

    /// Switching the input method on returns with macOS still asking: the hotkey stays down
    /// through the question, and comes up once the person allows it.
    @Test func anInputMethodSwitchedOnListensOnceThePersonAllowsIt() async {
        let rig = AppRig(switchedOn: false)
        rig.app.launch()
        await rig.until { rig.setUpShown == 1 }

        #expect(await rig.app.ask(.inputMethod) == .made)
        #expect(rig.installation.asking)
        rig.app.settle(rig.app.readiness())
        #expect(!rig.installation.isSelected)

        rig.installation.answer(allowing: true)
        rig.app.settle(rig.app.readiness())
        await rig.until { rig.app.hotkeyStatus == rig.listening() }
        #expect(rig.installation.isSelected)
    }

    /// An Escape the input method asks the app to take, off the main thread as the port hands it,
    /// puts the word box away with its held words; with no box shown, it is the app in front's.
    @Test func anEscapeTheInputMethodAsksAboutDismissesTheWordBox() async {
        let rig = AppRig()
        await rig.launched()
        let idle = FakeReply()
        rig.notices.ask(.escape(at: 0), through: idle)
        #expect(await idle.said() == .dismissal(.nothingShown))

        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        await rig.hold()
        await rig.until { rig.app.hold.held != nil }
        let shown = FakeReply()
        rig.notices.ask(.escape(at: 0), through: shown)
        #expect(await shown.said() == .dismissal(.dismissed))
        #expect(rig.app.hold.held == nil)
    }

    /// Words no cursor took are held, and the word box's Copy puts them on the pasteboard and
    /// dismisses them.
    @Test func copyingHeldWordsPutsThemOnThePasteboardAndDismissesThem() async {
        let rig = AppRig()
        await rig.launched()
        rig.app.copyHeld()
        #expect(rig.pasted.isEmpty)
        #expect(rig.lines.contains("asked to copy the held words with none held, so the clipboard is left as it was"))

        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        await rig.hold()
        await rig.until { rig.app.hold.held != nil }
        rig.app.copyHeld()
        #expect(rig.pasted == ["hello"])
        #expect(rig.app.hold.held == nil)
        #expect(rig.app.hold.dismissed != nil)
    }
}

