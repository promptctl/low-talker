import LowTalkerCore
import Uptime

/// The modifier feed's semantics, stated once. Each statement runs one fresh feed and says every
/// way it disagreed; nothing, when it agreed. `FakeModifierFeed` runs it. `ModifierMonitor` cannot
/// run inside the suite: its events come from the window server of a logged-in session.
/// [LAW:one-source-of-truth]
@MainActor
public struct ModifierFeedContract {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// An installed handler is told every modifier key that moves, in the order they moved.
        case anInstalledHandlerHearsEveryKey
        /// A disposed handler is told nothing more.
        case aDisposedHandlerHearsNothing
        /// A feed that cannot start throws from `install`.
        case aFeedThatCannotStartThrows

        public var description: String {
            switch self {
            case .anInstalledHandlerHearsEveryKey: "an installed handler hears every key"
            case .aDisposedHandlerHearsNothing: "a disposed handler hears nothing"
            case .aFeedThatCannotStartThrows: "a feed that cannot start throws"
            }
        }
    }

    /// One feed under test, and the keyboard it is told by.
    public struct Subject {
        public let feed: any ModifierFeed
        /// A modifier key moves on the keyboard.
        public let type: @MainActor (KeyEvent) -> Void

        public init(feed: any ModifierFeed, type: @escaping @MainActor (KeyEvent) -> Void) {
            self.feed = feed
            self.type = type
        }
    }

    /// A fresh feed: one that starts, or one that cannot when `refusing`.
    public let subject: @MainActor (_ refusing: Bool) -> Subject

    public init(subject: @escaping @MainActor (_ refusing: Bool) -> Subject) {
        self.subject = subject
    }

    static let keys = [
        KeyEvent(key: .rightOption, direction: .down, modifiers: [.rightOption], time: HostTime(uptime: .milliseconds(10)), lastTyped: HostTime(uptime: .zero)),
        KeyEvent(key: .leftShift, direction: .down, modifiers: [.rightOption, .leftShift], time: HostTime(uptime: .milliseconds(20)), lastTyped: HostTime(uptime: .zero)),
        KeyEvent(key: .rightOption, direction: .up, modifiers: [.leftShift], time: HostTime(uptime: .milliseconds(30)), lastTyped: HostTime(uptime: .zero)),
    ]

    public func disagreements(with statement: Statement) -> [String] {
        let subject = subject(statement == .aFeedThatCannotStartThrows)
        let told = Told()
        switch statement {
        case .anInstalledHandlerHearsEveryKey:
            do {
                let dispose = try subject.feed.install { told.keys.append($0) }
                defer { dispose() }
                Self.keys.forEach(subject.type)
                return told.keys == Self.keys ? [] : ["told \(told.keys) of \(Self.keys)"]
            } catch {
                return ["the feed would not start: \(error)"]
            }
        case .aDisposedHandlerHearsNothing:
            do {
                try subject.feed.install { told.keys.append($0) }()
                Self.keys.forEach(subject.type)
                return told.keys.isEmpty ? [] : ["a disposed handler was told \(told.keys)"]
            } catch {
                return ["the feed would not start: \(error)"]
            }
        case .aFeedThatCannotStartThrows:
            do {
                let dispose = try subject.feed.install { told.keys.append($0) }
                dispose()
                return ["a feed that cannot start installed a handler"]
            } catch {
                return []
            }
        }
    }
}

@MainActor private final class Told {
    var keys: [KeyEvent] = []
}
