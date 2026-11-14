import Dictation
import Grants
import InputSource
import Insertion
import LowTalkerCore
import Serve
import Uptime

extension LowTalkerApp {
    /// Every effect the app performs and every reading it takes, as one value: the real adapters
    /// in the app, and the one fake of each in a test. Nothing inside the app constructs an
    /// adapter of its own. [LAW:effects-at-boundaries] [LAW:single-enforcer]
    public struct Ports {
        /// The clock the launch's wait, the engine's readouts and every press are timed on. The
        /// hotkeys' feeds stamp their key events on this one clock.
        public var clock: HostClock
        /// This app's build, read off its bundle, which the input method's is compared with.
        public var build: Build
        public var microphone: any MicrophoneAuthority
        public var audio: any AudioHardware
        /// The modifier keys, one feed for each hotkey a rebuild puts up.
        public var modifiers: @MainActor () -> any ModifierFeed
        public var model: any ModelSupply
        public var config: any ConfigSource
        public var inputMethod: any InputMethodInstallation
        /// The input method's end of the insert port, one for each loop a rebuild builds.
        public var inserter: @MainActor () async -> any Inserter
        public var notices: any NoticeHost
        /// The input method's process, opened by its supervision.
        public var openInputMethod: @MainActor () async throws -> RunningInputMethod
        /// Where the words no cursor took are kept past the app.
        public var held: any HeldStore
        /// Where speech no engine heard is kept past the app.
        public var unheard: any UnheardStore
        /// The transcription server's switch, or nil in the build that cannot serve.
        public var server: ServerSwitch?
        /// Whether a Return typed while dictating is held for the dictated words.
        public var returnHolds: @Sendable () -> Bool
        /// Clears the general pasteboard and writes `text` to it, answering whether it took it.
        public var pasteboard: @MainActor (String) -> Bool
        /// The word box on screen.
        public var panel: any WordBoxPanel
        /// Shows the guided setup.
        public var showSetUp: @MainActor () -> Void
        /// Every record of what the app did, as it does it.
        public var told: @MainActor (Event) -> Void

        public init(
            clock: HostClock,
            build: Build,
            microphone: any MicrophoneAuthority,
            audio: any AudioHardware,
            modifiers: @escaping @MainActor () -> any ModifierFeed,
            model: any ModelSupply,
            config: any ConfigSource,
            inputMethod: any InputMethodInstallation,
            inserter: @escaping @MainActor () async -> any Inserter,
            notices: any NoticeHost,
            openInputMethod: @escaping @MainActor () async throws -> RunningInputMethod,
            held: any HeldStore,
            unheard: any UnheardStore,
            server: ServerSwitch?,
            returnHolds: @escaping @Sendable () -> Bool,
            pasteboard: @escaping @MainActor (String) -> Bool,
            panel: any WordBoxPanel,
            showSetUp: @escaping @MainActor () -> Void,
            told: @escaping @MainActor (Event) -> Void
        ) {
            self.clock = clock
            self.build = build
            self.microphone = microphone
            self.audio = audio
            self.modifiers = modifiers
            self.model = model
            self.config = config
            self.inputMethod = inputMethod
            self.inserter = inserter
            self.notices = notices
            self.openInputMethod = openInputMethod
            self.held = held
            self.unheard = unheard
            self.server = server
            self.returnHolds = returnHolds
            self.pasteboard = pasteboard
            self.panel = panel
            self.showSetUp = showSetUp
            self.told = told
        }
    }
}
