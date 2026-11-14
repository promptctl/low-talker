import Grants
import Identity
import InputSource
import Insertion
import LowTalkerApp
import LowTalkerCore
import Onboarding
import Testing
import Uptime

/// What the menu shows, read off the rows a set of readings makes.
@MainActor @Suite struct MenuTests {
    struct Stopped: Error, CustomStringConvertible {
        var description: String { "the device went away" }
    }

    /// An app with nothing to say beyond its status: ready, listening, typing.
    static func readings() -> Menu.Readings {
        Menu.Readings(
            engine: .ready(.default, after: .seconds(2)), engineReadout: "ready", serving: nil,
            microphone: .keeping(.shut), hotkey: .listening("hold Right Option"), inputMethodSelected: true,
            globeKey: .doNothing, running: .adopted(.default), lastFailure: nil, lastReplacement: nil, heldTroubles: [],
            dismissedWords: nil, keptSpeech: (lines: [], seconds: nil), benchRunning: false, readiness: Readiness([]),
            openAtLogin: .off, returnHolds: false)
    }

    /// The rows above the guided setup's item: what the menu says of the app's state.
    static func status(_ readings: Menu.Readings) -> [Menu.Row] {
        let rows = Menu(readings).rows
        return Array(rows.prefix { if case .item(_, .openSetUp, _) = $0 { false } else { true } })
    }

    static let quiet: [Menu.Row] = [
        .readout("Model: ready"),
        .readout("Microphone: \(AudioCapture.Doing.keeping(.shut))"),
        .readout("Hotkey: hold Right Option"),
    ]

    @Test func aReadyAppSaysItsStatusAndOffersEveryItem() {
        #expect(Menu(Self.readings()).rows == Self.quiet + [
            .item(GuidedSetup.title, .openSetUp, check: nil),
            .item("Benchmark…", .openBench, check: nil),
            .item("Open at Login", .toggleOpenAtLogin, check: .off),
            .item("Hold Return for Dictated Words", .toggleReturnHold, check: .off),
            .separator,
            .item("Acknowledgements", .openNotices, check: nil),
            .item("Quit \(AppIdentity.displayName)", .quit, check: nil),
        ])
    }

    @Test func aPreparingEngineSaysAPressNowWaitsForIt() {
        var readings = Self.readings()
        readings.engine = .preparing(.loading, since: HostTime(uptime: .seconds(1)))
        readings.engineReadout = "loading, 3 seconds so far"
        #expect(Array(Self.status(readings).prefix(2)) == [
            .readout("Model: loading, 3 seconds so far"),
            .readout("A press now is heard once the model is ready"),
        ])
    }

    @Test func aFailedEngineIsAnErrorRow() {
        var readings = Self.readings()
        readings.engine = .failed("no model")
        readings.engineReadout = "failed — no model"
        #expect(Self.status(readings).first == .failed("Model: failed — no model", .model))
    }

    @Test func aStoppedMicrophoneIsAnErrorRow() {
        var readings = Self.readings()
        readings.microphone = .stopped(.open, Stopped())
        #expect(Self.status(readings)[1] == .failed("Microphone: \(AudioCapture.Doing.stopped(.open, Stopped()))", .microphone))
    }

    /// Each standing of the input method's process that stops the words is said on the hotkey's
    /// line, as an error row; a running one says how to press.
    @Test func theHotkeyLineForEachStandingOfTheInputMethod() throws {
        let overrun = try #require(Overrun(footprint: 2 << 30, ceiling: 1 << 30))
        let off: [(InputMethodStanding, String)] = [
            (.ended(pid: 7), "the input method ended; \(AppIdentity.displayName) is starting it again"),
            (.overMemoryCeiling(pid: 7, overrun), "the input method is ending itself, \(overrun); \(AppIdentity.displayName) will start it again"),
            (.notOpened("refused"), "the input method could not be started: refused; trying again every \(InputMethodSupervisor.throttleInterval.formatted(.units(width: .wide)))"),
        ]
        for (standing, reason) in off {
            var readings = Self.readings()
            readings.hotkey = .showing(standing, listening: "unread")
            #expect(Self.status(readings)[2] == .failed("Hotkey: off — \(reason)", .hotkey), "\(standing)")
        }
        #expect(HotkeyStatus.showing(.running(pid: 7, build: .sameBuild), listening: "hold Fn") == .listening("hold Fn"))
    }

    @Test func aSourceNotSelectedSaysTheWordsAreNotTyped() {
        var readings = Self.readings()
        readings.inputMethodSelected = false
        #expect(Self.status(readings) == Self.quiet + [.readout("    Not typed now: \(AppIdentity.displayName) is not the selected input source")])
    }

    @Test func aGlobeKeyClashIsSaidOnlyForAChordHoldingFn() throws {
        var readings = Self.readings()
        readings.globeKey = .startDictation
        #expect(Self.status(readings) == Self.quiet)
        let fn = Mode(name: "dictation", chord: KeyChord(modifiers: .function))
        readings.running = .adopted(try Config(model: .default, microphone: .shut, modes: [fn], serve: .loopback))
        #expect(Self.status(readings) == Self.quiet + [
            .readout("    Fn also starts macOS Dictation: in System Settings › Keyboard, set “Press 🌐 key to” to Do Nothing"),
        ])
    }

    @Test func heldWordsThatFailedToKeepAreErrorRowsAndDismissedOnesCanComeBack() {
        var readings = Self.readings()
        readings.heldTroubles = ["could not be kept"]
        readings.dismissedWords = 3
        #expect(Self.status(readings) == Self.quiet + [
            .failed("Held words: could not be kept", .heldWords),
            .item("Bring Back Dismissed Words (3)", .bringBackDismissed, check: nil),
        ])
    }

    @Test func keptSpeechIsSaidAndCanBeDiscarded() {
        var readings = Self.readings()
        readings.keptSpeech = (lines: ["4 s of speech kept until a model loads"], seconds: 4)
        #expect(Self.status(readings) == Self.quiet + [
            .failed("4 s of speech kept until a model loads", .keptSpeech),
            .item("Discard Kept Speech (4 s)", .discardKeptSpeech, check: nil),
        ])
    }

    @Test func aRefusedConfigIsAnErrorRow() {
        var readings = Self.readings()
        let kept = RunningConfig.kept(.default, because: .noModes)
        readings.running = kept
        #expect(Self.status(readings) == Self.quiet + [.failed("Config: \(kept)", .config)])
    }

    @Test func aLastDictationsFailureAndReplacementAreSaid() {
        var readings = Self.readings()
        readings.lastFailure = "no text field had focus"
        readings.lastReplacement = "Last dictation replaced 5 selected characters"
        #expect(Self.status(readings) == Self.quiet + [
            .failed("no text field had focus", .lastDictation),
            .readout("Last dictation replaced 5 selected characters"),
        ])
    }

    @Test func everyRequirementIsListedAndTheSetUpItemCountsWhatIsLeft() {
        var readings = Self.readings()
        readings.readiness = OnboardingProbe.readiness(microphone: .withheld(.denied), inputMethodSwitchedOn: true)
        let rows = Menu(readings).rows
        for requirement in readings.readiness.requirements {
            #expect(rows.contains(.readout("\(requirement.name): \(requirement.reads)")))
        }
        #expect(rows.contains(.item("\(GuidedSetup.title) (1 left)", .openSetUp, check: nil)))
    }

    @Test func openAtLoginWaitingOnSystemSettingsIsMixedAndSaysWhy() {
        var readings = Self.readings()
        readings.openAtLogin = .requiresApproval
        let rows = Menu(readings).rows
        let item = rows.firstIndex(of: .item("Open at Login", .toggleOpenAtLogin, check: .mixed))
        #expect(item.map { rows[$0 + 1] } == .readout("    \(LoginItemStatus.requiresApproval)"))
    }
}
