// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "low-talker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LowTalkerCore", targets: ["LowTalkerCore"]),
        .library(name: "Grants", targets: ["Grants"]),
        .library(name: "Identity", targets: ["Identity"]),
        .library(name: "Onboarding", targets: ["Onboarding"]),
        .library(name: "MenuBarPresence", targets: ["MenuBarPresence"]),
        .library(name: "StatusMenu", targets: ["StatusMenu"]),
        .library(name: "Signals", targets: ["Signals"]),
        .library(name: "Dictation", targets: ["Dictation"]),
        .library(name: "InputMethod", targets: ["InputMethod"]),
        .library(name: "Insertion", targets: ["Insertion"]),
        .library(name: "InputSource", targets: ["InputSource"]),
        .library(name: "Serve", targets: ["Serve"]),
        .library(name: "Bench", targets: ["Bench"]),
        .executable(name: "lowtalker-inputmethod", targets: ["lowtalker-inputmethod"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // WhisperKit ships inside the Argmax OSS SDK since 1.0; the WhisperKit product
        // is the only one linked.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        // [LAW:one-way-deps] Core knows nothing of the app; the app links it.
        // The names macOS keys LowTalker by. It depends on nothing, so the input method process and the app's
        // upper layers can both read it without either depending on the other.
        // [LAW:one-way-deps]
        .target(name: "Identity"),
        .testTarget(name: "IdentityTests", dependencies: ["Identity"]),
        // The Text Input Sources framework as this program uses it: where the
        // input source stands on this Mac, and the steps that put it there. It links only
        // Identity and the Text Input Sources lock beneath it, so the app reaches it without
        // the input method process linking anything of the app's. [LAW:one-way-deps]
        .target(name: "InputSource", dependencies: ["Identity", "TextInputSources"]),
        .testTarget(name: "InputSourceTests", dependencies: ["InputSource", "Identity"]),
        // What macOS has let this process do - listen - read without ever prompting, and asked
        // for only when called. Beneath the core and the setup list alike, so both read one
        // reading. [LAW:one-way-deps]
        .target(name: "Grants"),
        .testTarget(name: "GrantsTests", dependencies: ["Grants"]),
        .target(
            name: "LowTalkerCore",
            dependencies: [
                "Identity",
                "Grants",
                // The app's end of the hotkey port, which the input method tells the modifier
                // keys to.
                "Insertion",
                "CoreAudioCalls",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        // OpenAI's speech-to-text API over any Transcriber, for callers other than
        // dictation (epic low-serve-axq). Above the core, so the core never links Network
        // and the offline build's app need not link this at all. [LAW:one-way-deps]
        .target(name: "Serve", dependencies: ["LowTalkerCore", "Identity"]),
        .testTarget(name: "ServeTests", dependencies: ["Serve", "LowTalkerCore", "Identity", "TestProbes"], resources: [.copy("Fixtures")]),
        // Answering a signal rather than obeying it, for every process here that has an
        // ending of its own to unwind through. It links nothing, so any process here can
        // watch through it. [LAW:one-source-of-truth]
        .target(name: "Signals"),
        // What more than one suite builds: the gate and the flag a suite plants in
        // concurrent work to see where it has got to, and the scratch store the core's read
        // side and the installer's write side are both exercised on. A plain target because
        // test targets cannot import one another's sources, and in no product because
        // nothing ships it. [LAW:one-source-of-truth]
        .target(name: "TestProbes", dependencies: ["LowTalkerCore"]),
        // Everything that must hold before low-talker can hear and type, as a list a reader
        // can act on: what was read off this Mac, and the step for whatever is missing. It
        // links the identity, the grants and the input source's switch, and not the core - so
        // the menu and the guided setup show the same words off one list.
        // [LAW:one-source-of-truth] [LAW:one-way-deps]
        .target(name: "Onboarding", dependencies: ["Identity", "Grants", "InputSource"]),
        // The steps are what a person acts on, so they are asserted as values rather
        // than scraped off a terminal.
        .testTarget(name: "OnboardingTests", dependencies: ["Onboarding", "Identity", "Grants"]),
        // Whether the app's icon is in the menu bar as its own: which process macOS holds
        // responsible for it, which decides whose row in the menu bar's allow list it is filed
        // under, and whether the icon came on screen. Out of the app target so `make test` runs it.
        // [LAW:decomposition]
        .target(name: "MenuBarPresence", dependencies: ["Identity"]),
        .testTarget(name: "MenuBarPresenceTests", dependencies: ["MenuBarPresence"]),
        // The rows of the status item's menu that do more than AppKit's own items: an error a
        // click copies. Out of the app target so `make test` runs it. [LAW:decomposition]
        .target(name: "StatusMenu"),
        .testTarget(name: "StatusMenuTests", dependencies: ["StatusMenu"]),
        .testTarget(name: "SignalsTests", dependencies: ["Signals", "LowTalkerCore", "TestProbes"]),
        // The loop from a press to inserted text, with every collaborator taken as a value.
        // Its own target rather than app code so the loop runs under `swift test`; the
        // app links it and hands over the real microphone, engine and inserter - the input
        // method in the app, a fake in a test. [LAW:decomposition] [LAW:composability]
        .target(name: "Dictation", dependencies: ["LowTalkerCore", "Insertion"]),
        .testTarget(name: "DictationTests", dependencies: ["Dictation", "LowTalkerCore", "Grants", "Insertion", "TestProbes"]),
        // What the input method process answers with, kept out of the process itself so the
        // suite compiles and exercises it: an Xcode-only target would be invisible to
        // `make test` the way App/LowTalker's sources are.
        .target(name: "InputMethod", dependencies: ["Insertion"]),
        .testTarget(name: "InputMethodTests", dependencies: ["InputMethod", "Insertion", "Identity"]),
        // The two calls that cross between the app and the input method - words one way, the
        // modifier keys the other - and both ends of each port. It links Identity for the
        // ports' names and the Darwin calls beneath them, and nothing else - in particular no
        // InputMethodKit, because the app is one of its two callers and the app has no
        // business linking the text input system.
        // [LAW:one-way-deps]
        .target(name: "Insertion", dependencies: ["Identity", "DarwinCalls"]),
        // The bootstrap calls the SDK keeps from Swift, the Mach macros Swift cannot import
        // and the kernel's code signing call, each passed through by a line of C and nothing
        // more.
        .target(name: "DarwinCalls"),
        // CoreAudio's listener block calls, passed through by a line of C each so the block
        // a listener is removed with is the block it was added with. Its own target rather
        // than DarwinCalls', which the input method links and which should not bring
        // CoreAudio with it.
        .target(name: "CoreAudioCalls"),
        // The one lock every call into Text Input Sources takes, since the API aborts the
        // process when two threads meet inside it.
        .target(name: "TextInputSources"),
        // A sender that is not the test process, so the insert port's refusal is held by a
        // request that really crossed from another process. In no product: nothing ships it.
        .executableTarget(name: "insertion-probe", dependencies: ["Insertion", "Identity"], path: "Tests/InsertionProbe"),
        .testTarget(name: "InsertionTests", dependencies: ["Insertion", "Identity", "DarwinCalls", "insertion-probe"]),
        // The process macOS launches out of the input method bundle. It holds the effects -
        // reading the bundle, opening the port, running the loop - and nothing else.
        .executableTarget(name: "lowtalker-inputmethod", dependencies: ["InputMethod", "Insertion", "Identity"]),
        // The bench: its options, flags, table, the folders a person picked for it, and the
        // one run at a time the app's window and `LowTalker --bench` start. Beneath the app;
        // the engine it loads is the core's, read in place, never installed.
        .target(name: "Bench", dependencies: ["LowTalkerCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "BenchTests", dependencies: ["Bench", "LowTalkerCore", "TestProbes"]),
        // The write side of the model store: fetching from huggingface.co or a published
        // base, copying from another store, packing one to publish. Beneath `model-tool`
        // alone.
        // The app links the core and loads the store its bundle carries, read-only, so the
        // graph and not the call sites is what says the app cannot download;
        // `AppLinksNoInstallerTests` reads this graph for that. [LAW:one-way-deps]
        .target(name: "ModelInstall", dependencies: ["LowTalkerCore", .product(name: "WhisperKit", package: "argmax-oss-swift")]),
        // What the build runs to name, check, fetch and pack the model a bundle carries. Like
        // insertion-probe it is in no product, and project.yml never copies it into a bundle,
        // so nothing a person installs runs it. [LAW:one-way-deps]
        .executableTarget(name: "model-tool", dependencies: ["ModelInstall", "LowTalkerCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "ModelToolTests", dependencies: ["model-tool", "ModelInstall", "LowTalkerCore"]),
        .testTarget(
            name: "ModelInstallTests",
            dependencies: [
                "ModelInstall",
                "LowTalkerCore",
                "TestProbes",
                // The tokenizer-choice test holds the installer's mirror of WhisperKit's
                // internal decision to WhisperKit's own functions.
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "LowTalkerCoreTests",
            dependencies: [
                "LowTalkerCore",
                "Grants",
                "Insertion",
                "TestProbes",
                // The tests build WhisperKit's result types by hand to exercise the
                // mapping without model weights.
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
