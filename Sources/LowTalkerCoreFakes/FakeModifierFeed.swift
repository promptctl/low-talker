import LowTalkerCore
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
        return { installation.disposed = true }
    }

    /// A modifier key moved, and every handler still installed is told.
    public func type(_ event: KeyEvent) {
        for installation in installations where !installation.disposed { installation.handle(event) }
    }
}
