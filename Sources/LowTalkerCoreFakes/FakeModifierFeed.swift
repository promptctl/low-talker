import LowTalkerCore
import TestProbes
import Uptime

/// A keyboard a test types on, standing in the window server's modifier events. Every handler
/// installed and not yet disposed is told each key the test moves, and it keeps
/// `ModifierFeedContract`.
@MainActor
public final class FakeModifierFeed: ModifierFeed {
    public final class Installation {
        public let handle: @MainActor (KeyEvent) -> Void
        public internal(set) var disposed = false

        init(handle: @escaping @MainActor (KeyEvent) -> Void) {
            self.handle = handle
        }
    }

    /// Every handler installed, in order, disposed or not.
    public private(set) var installations: [Installation] = []
    /// The clock the test stamps the keys it types on.
    public let clock: HostClock
    private let refusal: (any Error)?
    private var changes: Changes?

    /// Notes `changes` at every install and disposal, so a test awaits a hotkey going up or down.
    public func noting(_ changes: Changes) { self.changes = changes }

    /// A keyboard whose keys are stamped on `clock`. A feed that cannot start throws `refusal`
    /// from every install.
    public init(on clock: HostClock, refusing refusal: (any Error)? = nil) {
        self.clock = clock
        self.refusal = refusal
    }

    public func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal {
        if let refusal { throw refusal }
        let installation = Installation(handle: handle)
        installations.append(installation)
        changes?.note()
        return { [weak self] in
            installation.disposed = true
            self?.changes?.note()
        }
    }

    /// A modifier key moved, and every handler still installed is told. [LAW:single-enforcer]
    /// A key is told once it has been stamped, so a stamp later than the feed's clock is a test
    /// describing a keyboard that cannot exist, and it stops here.
    public func type(_ event: KeyEvent) {
        precondition(event.time <= clock.now, "a key stamped at \(event.time.uptime) was typed while the feed's clock read \(clock.now.uptime)")
        for installation in installations where !installation.disposed { installation.handle(event) }
    }
}
