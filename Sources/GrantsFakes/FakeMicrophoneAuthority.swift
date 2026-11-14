import AVFoundation
import Grants
import Synchronization

/// A TCC a test controls: a status, and the decision the person makes at the prompt. It keeps
/// `MicrophoneAuthorityContract` as macOS does: only an undetermined status prompts, and a
/// decided one is answered from what was decided.
public final class FakeMicrophoneAuthority: MicrophoneAuthority {
    private let current: Mutex<AVAuthorizationStatus>
    /// What the status becomes when the prompt is answered.
    private let decision: AVAuthorizationStatus

    public init(status: AVAuthorizationStatus = .authorized, decision: AVAuthorizationStatus = .authorized) {
        current = Mutex(status)
        self.decision = decision
    }

    public func status() -> AVAuthorizationStatus { current.withLock { $0 } }

    /// The person changed their mind in System Settings.
    public func set(_ status: AVAuthorizationStatus) { current.withLock { $0 = status } }

    public func requestAccess() async -> Bool {
        current.withLock { status in
            if status == .notDetermined { status = decision }
            return status == .authorized
        }
    }
}
