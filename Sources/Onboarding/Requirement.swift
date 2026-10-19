import Identity
import Grants

/// One thing that must hold before low-talker can hear and type, as this Mac actually stands.
///
/// [LAW:one-type-per-behavior] Different facts - a privacy grant only a person can give, an
/// input method macOS switches on - are one type with one instance per row, because what a
/// reader does with them does not differ: read what is there, and do the step when there is
/// one. A type per requirement would be a rendering per requirement of one shape.
public struct Requirement: Sendable, Hashable {
    /// Which requirement this is. Its name, its explanation and what asking for it does are
    /// all read off the row, so no reader keeps a second copy of any of them.
    public let row: Row
    /// What was read off this Mac. Shown whether or not there is a step, because a
    /// requirement that says only "not ready" is one nobody can act on or report.
    public let reads: String
    /// What is left for a person to do, and nil when nothing is. Genuinely absent rather
    /// than an empty string: "nothing to do" and "a step nobody wrote" are different
    /// facts, and a reader that cannot tell them apart will print the second as the
    /// first.
    public let step: String?

    /// What must hold, in the words the menu and the guided setup both use.
    public var name: String { row.rawValue }

    public var met: Bool { step == nil }

    public init(row: Row, reads: String, step: String?) {
        self.row = row
        self.reads = reads
        self.step = step
    }
}

public extension Requirement {
    /// Every requirement there is, in the order the menu shows them and the guided setup
    /// walks them. Each one stops dictation until it is met: nothing is heard without the
    /// microphone, and nothing reaches the cursor or hears the chord without the input
    /// method.
    ///
    /// This is the one list of what low-talker asks of a Mac. The menu shows it and the
    /// guided setup is a walk over it, so a grant added here reaches every
    /// surface and a grant missing here is missing from all of them. [LAW:one-source-of-truth]
    enum Row: String, Sendable, Hashable, CaseIterable {
        case microphone = "Microphone"
        case inputMethod = "Input method"

        /// Whether pressing this row's ask button again asks macOS again. Most of these
        /// dialogs macOS shows once per app, so a second press does nothing and the step
        /// sends the person to System Settings instead. Switching on an input method is not
        /// one of them: macOS shows its Allow dialog every time the app asks. Measured on
        /// studious 2026-09-27 (low-input-method-s71.ssn) - declined, the dialog comes back
        /// on the next press - so the button stays and the row is never given the "asks only
        /// once" line or sent to System Settings.
        public var reAskable: Bool {
            switch self {
            case .inputMethod: true
            case .microphone: false
            }
        }
    }

    /// A requirement whose fact could not be read.
    ///
    /// The row stays in the list rather than being dropped or skipped: every requirement
    /// is shown every time, and one that could not be read is never silently absent from
    /// a list a reader takes as complete. It carries a step, so it is never `met` and
    /// never lets `ready` come out true on the strength of a reading nobody took.
    /// [LAW:no-silent-failure]
    static func unreadable(_ row: Row, _ error: any Error) -> Requirement {
        Requirement(row: row, reads: "could not be read", step: "\(error)")
    }
}

public extension Requirement {
    /// The step as the lines it was written in, and no lines at all when there is
    /// nothing to do. Split here so that the menu, which makes one item per line, and the
    /// guided setup work from one shape rather than each taking a string apart its own way.
    /// [LAW:one-source-of-truth]
    var stepLines: [String] { step.map { $0.components(separatedBy: "\n") } ?? [] }
}

/// Where this Mac stands against everything low-talker needs, as one list.
///
/// This is what the menu-bar app shows and what its guided setup walks. It is computed
/// rather than printed so a test can read it as a value, and so every surface says the same
/// words without any of them spelling them a second time. [LAW:effects-at-boundaries]
public struct Readiness: Sendable {
    /// Every requirement, every time, in a fixed order - the met ones included. A list
    /// that showed only what was wrong would leave a reader unable to tell "checked and
    /// fine" from "never checked". [LAW:dataflow-not-control-flow]
    public let requirements: [Requirement]

    public init(_ requirements: [Requirement]) {
        self.requirements = requirements
    }

    /// Nothing is left for anyone to do.
    public var ready: Bool { requirements.allSatisfy(\.met) }

    /// The requirements with something left to do, in the list's order.
    public var unmet: [Requirement] { requirements.filter { !$0.met } }
}

// MARK: - the privacy grants

/// Where each privacy grant is switched on by hand. Named once, because every step that
/// sends a reader to one of these panes spells it from here.
private func privacyPane(_ row: Requirement.Row) -> String {
    "System Settings > Privacy & Security > \(row.rawValue)"
}

public extension Requirement {
    /// The microphone, which every setup needs: nothing is heard without it.
    ///
    /// - Parameter withheld: why macOS withholds it, or nil when it is allowed.
    static func microphone(_ withheld: MicrophoneAuthorization.Withheld?) -> Requirement {
        Requirement(row: .microphone, reads: reads(forMicrophone: withheld), step: step(forMicrophone: withheld))
    }

    private static func reads(forMicrophone withheld: MicrophoneAuthorization.Withheld?) -> String {
        switch withheld {
        case nil: "allowed"
        case .notDetermined: "not asked yet"
        case .denied: "turned off"
        case .restricted: "restricted by policy"
        }
    }

    private static func step(forMicrophone withheld: MicrophoneAuthorization.Withheld?) -> String? {
        switch withheld {
        case nil:
            nil
        case .notDetermined:
            "Allow it in \(GuidedSetup.title)"
        case .denied:
            "Turn on \(AppIdentity.displayName) in \(privacyPane(.microphone))."
        case .restricted:
            "A policy on this Mac blocks it."
        }
    }
}

// MARK: - the input method

public extension Requirement {
    /// Whether the input method is switched on. macOS asks the person before
    /// an app may switch one on, so this is a grant, and the one dictation waits on. Copying
    /// and registering it ask nobody, and the app does both on its own.
    static func inputMethod(switchedOn: Bool) -> Requirement {
        Requirement(row: .inputMethod, reads: reads(forSwitchedOn: switchedOn), step: switchedOn ? nil : "Switch it on in \(GuidedSetup.title)")
    }

    private static func reads(forSwitchedOn switchedOn: Bool) -> String {
        switchedOn ? "switched on" : "switched off"
    }
}

// MARK: - the vocabulary docs/engineering.md keeps a copy of

public extension Requirement {
    /// Every reading every row can take, each paired with the row it belongs to.
    ///
    /// docs/engineering.md lists these for a reader following the runbook by hand. It cannot read a
    /// Swift enum, so it keeps a copy per row, and `RequirementTests` holds
    /// each copy to it. Derived from the same functions the rows themselves are built from
    /// rather than written out a second time, so a reading added to a row reaches every
    /// reader that quotes the list. [LAW:one-source-of-truth]
    ///
    /// `unreadable`'s reading is in none of them: it belongs to no row's own vocabulary,
    /// being the one thing every row says when the machine could not be read, and docs/engineering.md
    /// describes it once as exactly that.
    static var readings: [(row: Row, reading: String)] {
        all.map { (row: $0.row, reading: $0.reads) }
    }

    /// Every requirement there can be: each row once per reading it can take.
    static var all: [Requirement] {
        ([nil] + MicrophoneAuthorization.Withheld.allCases).map(microphone) + [true, false].map(inputMethod(switchedOn:))
    }
}
