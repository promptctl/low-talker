import InputSource

/// An input method installation's semantics, stated once. Each statement runs one fresh
/// installation and says every way it disagreed; nothing, when it agreed.
/// `FakeInputMethodInstallation` runs it. `InstalledInputMethod` cannot run inside the suite: its
/// every step writes this Mac's input sources. [LAW:one-source-of-truth]
@MainActor
public struct InputMethodInstallationContract {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// Selected while switched off, it stops at switched off and is not the source in use.
        case aSwitchedOffInputMethodIsNotSelected
        /// Selected while switched on, it is the source in use.
        case aSwitchedOnInputMethodIsSelected
        /// Switching on returns with macOS still asking: it is not switched on until the person
        /// allows it, and the next select then selects it.
        case switchedOnOnceAllowedThenSelectedIsSelected

        public var description: String {
            switch self {
            case .aSwitchedOffInputMethodIsNotSelected: "a switched-off input method is not selected"
            case .aSwitchedOnInputMethodIsSelected: "a switched-on input method is selected"
            case .switchedOnOnceAllowedThenSelectedIsSelected: "switched on once allowed, then selected, is selected"
            }
        }
    }

    /// A fresh installation, switched on or not, and its person allowing it once asked.
    public typealias Subject = (installation: any InputMethodInstallation, allow: @MainActor () -> Void)

    public let subject: @MainActor (_ switchedOn: Bool) -> Subject

    public init(subject: @escaping @MainActor (_ switchedOn: Bool) -> Subject) {
        self.subject = subject
    }

    public func disagreements(with statement: Statement) async throws -> [String] {
        switch statement {
        case .aSwitchedOffInputMethodIsNotSelected:
            let installation = subject(false).installation
            let readiness = try await installation.select()
            return readiness == .switchedOff && !installation.isSelected ? [] : ["switched off, select read \(readiness) and selected \(installation.isSelected)"]
        case .aSwitchedOnInputMethodIsSelected:
            let installation = subject(true).installation
            let readiness = try await installation.select()
            return readiness == .selected && installation.isSelected ? [] : ["switched on, select read \(readiness) and selected \(installation.isSelected)"]
        case .switchedOnOnceAllowedThenSelectedIsSelected:
            let (installation, allow) = subject(false)
            try await installation.switchOn()
            guard !installation.isSwitchedOn else { return ["switching on read switched on before the person allowed it"] }
            allow()
            guard installation.isSwitchedOn else { return ["allowed, switching on left it off"] }
            let readiness = try await installation.select()
            return readiness == .selected && installation.isSelected ? [] : ["switched on, select read \(readiness) and selected \(installation.isSelected)"]
        }
    }
}
