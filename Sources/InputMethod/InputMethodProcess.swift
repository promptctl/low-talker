import AppKit
import Carbon
import Identity
import Insertion
import os

/// What the input method reads of the Mac it runs on, each read on the main actor where the
/// effects are and handed to the decisions as values. [LAW:effects-at-boundaries] A test hands in
/// the readings it means; the shipped process's are `shipped`.
public nonisolated struct Readings: Sendable {
    /// The app in front, by bundle identifier.
    public let frontmost: @MainActor @Sendable () -> String?
    /// Whether this input method's source is the one in use.
    public let selected: @MainActor @Sendable () -> Bool
    /// The screens' frames, which a caret has to be on to be a field's.
    public let screens: @MainActor @Sendable () -> [CGRect]
    /// This process's footprint in bytes, or nil where the kernel will not say it.
    public let footprint: @MainActor @Sendable () -> UInt64?

    init(frontmost: @escaping @MainActor @Sendable () -> String?, selected: @escaping @MainActor @Sendable () -> Bool,
                screens: @escaping @MainActor @Sendable () -> [CGRect], footprint: @escaping @MainActor @Sendable () -> UInt64?) {
        (self.frontmost, self.selected, self.screens, self.footprint) = (frontmost, selected, screens, footprint)
    }

    /// The workspace, the text input system, the window server and the kernel.
    public static let shipped = Readings(
        frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        selected: isTheSelectedSource,
        screens: { NSScreen.screens.map(\.frame) },
        footprint: ownFootprint)

    /// Whether this input method's source is the one in use, read from the text input system.
    /// No current source, or one that names no identifier, is not this one.
    @MainActor
    private static func isTheSelectedSource() -> Bool {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let identifier = current.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceID) }
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        return identifier == AppIdentity.inputSourceIdentifier
    }
}

/// The input method's parts, put together once: the cursors, what the app is told, how Return and
/// Escape are decided, where inserts are committed, and what is read of the Mac.
///
/// [LAW:no-shared-mutable-globals] `IMKServer` builds controllers out of a class name, so the shipped
/// process's controllers take `shipped`, the one place it is assembled, and the entry point opens its
/// ports onto the same one. A test assembles its own from fakes and drives it whole.
public nonisolated struct InputMethodProcess: Sendable {
    public let focused: FocusedClient
    public let notices: Notices
    public let steering: Steering
    public let committer: Committer
    public let readings: Readings

    /// `steering` beeps through `beep`, and the committer waits on `gate`'s turns, so a Return held
    /// on the main actor lets the commit it waits for run. Both are made here, of the parts handed
    /// in, so no assembly can give them others. [LAW:single-enforcer]
    init(readings: Readings, notices: Notices, gate: SteeringGate, beep: @escaping @MainActor @Sendable () -> Void,
         bound: Duration = Committer.standardBound, told: @escaping @Sendable (Ended) -> Void) {
        self.readings = readings
        self.notices = notices
        self.focused = FocusedClient(arrived: notices.cursorArrived(in:))
        self.steering = Steering(gate: gate, beep: beep)
        self.committer = Committer(bound: bound, turns: gate.turns, told: told)
    }

    /// The shipped process's: the Mac's readings, notices said in the log, the system beep, and
    /// each commit's end said in the log.
    public static let shipped = InputMethodProcess(
        readings: .shipped, notices: Notices { $0.log() }, gate: SteeringGate(), beep: { NSSound.beep() },
        told: { ended in processLog.notice("\(ended.description, privacy: .public)") })

    /// Answers `request` within the committer's bound, from the cursor in front as the readings
    /// find it on the main actor. Blocks the caller, so it belongs on the insert port's queue.
    public func insert(_ request: InsertRequest) -> Placed {
        committer.insert(request) { [focused, readings] in
            focused.inFront(for: request.destination, whileInFrontIs: readings.frontmost(), selected: readings.selected(),
                            screens: readings.screens())
        }
    }
}

/// The input method's own lines: its entry point's and each commit's end. [LAW:one-source-of-truth]
public nonisolated let processLog = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "inputmethod")
