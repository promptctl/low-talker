import AppKit

/// What IMK handed `handle`, read off the event where it arrives, off the main actor: no event,
/// which IMK sends after an activate (low-input-method-8vv); an event that is no key-down, which
/// nothing asks for; or a key-down.
///
/// [LAW:parse-dont-validate] The one place an event becomes a key. Only what steering needs crosses
/// the hop, never the event or which key it was, so nothing past here can say what was typed.
/// `keyCode` raises on an event that is no key, so nothing is read from one.
nonisolated enum Handed: Sendable {
    case noEvent
    case noKey
    case key(KeyDown)

    init(_ event: NSEvent?) {
        guard let event else { self = .noEvent; return }
        guard event.type == .keyDown else { self = .noKey; return }
        self = .key(KeyDown(steering: SteeringKey(keyCode: event.keyCode, holding: event.modifierFlags),
                            typedAt: event.timestamp, repeats: event.isARepeat))
    }
}

/// A key-down, as steering reads it.
nonisolated struct KeyDown: Sendable {
    /// The steering key it is, or nil for any other key.
    let steering: SteeringKey?
    /// The moment it went down, on the system-uptime clock the gate's questions are asked about.
    let typedAt: TimeInterval
    /// Whether it is the key's own auto-repeat while it is held, rather than a press.
    let repeats: Bool
}
