import Identity
import Foundation

/// The app's guided setup: the onboarding list walked one requirement at a time, each one
/// explained before macOS is asked for anything.
///
/// [LAW:one-source-of-truth] A view of `Readiness` and nothing more. Which steps there are,
/// and whether each is done, is read off the list every time; the walk remembers only which
/// steps the person chose to skip, which is the one thing the list cannot know.
public struct GuidedSetup: Sendable, Equatable {
    /// The steps the person set aside in this walk. Kept only while the walk is open: a
    /// skipped step is offered again the next time setup opens.
    public private(set) var skipped: Set<Requirement.Row> = []

    public init() {}

    /// What the menu item and every step that points at the setup call it.
    public static let title = "Set Up \(AppIdentity.displayName)…"

    /// The buttons every step shows beside its ask, named here because a step's words send
    /// the person to them.
    public static let checkAgainTitle = "Check Again"
    public static let openSettingsTitle = "Open System Settings"

    /// The step to show: the first requirement with something left to do that the person
    /// has not set aside, or nil when there is none and the walk shows where things stand.
    public func current(in readiness: Readiness) -> Requirement? {
        readiness.unmet.first { !skipped.contains($0.row) }
    }

    /// Sets a step aside, so the walk moves on without it. Declining is not an error: the
    /// app keeps running, and the step waits in the summary with what skipping it costs.
    public mutating func skip(_ row: Requirement.Row) {
        skipped.insert(row)
    }

    /// Brings a skipped step back, which is how the summary resumes the walk at it.
    public mutating func revisit(_ row: Requirement.Row) {
        skipped.remove(row)
    }
}

/// Why a requirement is asked for, in the words a person reads before macOS asks them
/// anything: what it is for, and what happens without it. One sentence each, at most two.
public struct Explanation: Sendable, Hashable {
    public let why: String
    public let ifSkipped: String
}

public extension Requirement.Row {
    /// This step's explanation.
    ///
    /// [LAW:types-are-the-program] An exhaustive switch, so a row added to the list cannot
    /// compile without the answers a person needs before being asked for it.
    var explanation: Explanation {
        let app = AppIdentity.displayName
        return switch self {
        case .microphone:
            Explanation(
                why: "\(app) listens only while you hold your dictation key. Audio stays on this Mac.",
                ifSkipped: "\(app) can't hear you.")
        case .inputMethod:
            Explanation(
                why: "Hears your dictation key and puts your words at the cursor in any app.",
                ifSkipped: "\(app) can't hear your dictation key, and your words can't reach the cursor.")
        }
    }

    /// The button that asks macOS, named for what it asks. The ellipsis says a dialog
    /// follows.
    var askTitle: String {
        switch self {
        case .microphone: "Allow Microphone…"
        case .inputMethod: "Switch On Input Method…"
        }
    }

    /// The System Settings pane where this grant is switched by hand, which is where a
    /// person goes after declining macOS's dialog: the microphone's is shown once.
    var settingsPane: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .inputMethod: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        }
    }

    /// What pressing this row's ask button does, and what to do when it does not take: for
    /// what the explanation cannot say and the once-asked note gets wrong. Only the input
    /// method has one. macOS shows an Allow dialog naming the app each time it is asked
    /// (studious 2026-09-27, low-input-method-s71.ssn), so declining is not the end - the
    /// button stays and asks again. When no dialog comes, the switch is under Input Sources
    /// in the pane this step opens. [LAW:no-silent-failure] Keyed on what the person can
    /// see - a dialog, or nothing - and every way on is a button on this page.
    var switchOnNote: String? {
        switch self {
        case .inputMethod:
            """
            macOS asks whether to allow \(AppIdentity.displayName) to switch it on: click Allow. \
            You can press this again if you decline. If pressing it changes nothing, click \
            \(GuidedSetup.openSettingsTitle), add \(AppIdentity.displayName) under Input Sources, \
            then click \(GuidedSetup.checkAgainTitle).
            """
        case .microphone:
            nil
        }
    }
}
