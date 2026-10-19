import IOKit.hidsystem
import Insertion

/// Where the hotkey is told each modifier key moving.
///
/// [LAW:effects-at-boundaries] What tells it is an effect against another process - the
/// input method, and the session's modifier state behind it - so it sits behind this seam,
/// and the press detection above runs in tests against a keyboard a test types on.
@MainActor
public protocol ModifierFeed {
    /// Starts telling `handle`, on the main actor, every modifier key that moves, until the
    /// disposal it answers with is called. Throws when it cannot start.
    func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal
}

extension Modifier {
    /// The bit the session's flags carry while this modifier is held: the device-side one
    /// from IOLLEvent.h, which tells left from right where the CoreGraphics masks do not.
    var mask: UInt64 {
        switch self {
        case .leftShift: UInt64(NX_DEVICELSHIFTKEYMASK)
        case .rightShift: UInt64(NX_DEVICERSHIFTKEYMASK)
        case .leftControl: UInt64(NX_DEVICELCTLKEYMASK)
        case .rightControl: UInt64(NX_DEVICERCTLKEYMASK)
        case .leftOption: UInt64(NX_DEVICELALTKEYMASK)
        case .rightOption: UInt64(NX_DEVICERALTKEYMASK)
        case .leftCommand: UInt64(NX_DEVICELCMDKEYMASK)
        case .rightCommand: UInt64(NX_DEVICERCMDKEYMASK)
        // The Fn key itself in `SessionModifiers.flags`, which is where every reading here
        // comes from; as the session sets it, the bit also rides on the arrow and navigation
        // keys.
        case .function: UInt64(NX_SECONDARYFNMASK)
        }
    }

    /// The modifiers a set of session flags says are held.
    static func held(in flags: UInt64) -> Set<Modifier> {
        Set(allCases.filter { flags & $0.mask != 0 })
    }

    /// The modifiers the session holds now.
    static func heldInSession() -> Set<Modifier> {
        held(in: SessionModifiers.read().flags)
    }
}
