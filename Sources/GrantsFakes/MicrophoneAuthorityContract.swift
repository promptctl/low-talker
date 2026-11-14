import AVFoundation
import Grants

/// Microphone authorization's semantics, stated once. Each statement runs one fresh authority and
/// says every way it disagreed; nothing, when it agreed. `FakeMicrophoneAuthority` runs it.
/// `SystemMicrophoneAuthority` cannot run inside the suite: a request there is a prompt nobody
/// answers. [LAW:one-source-of-truth]
public struct MicrophoneAuthorityContract: Sendable {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// A request answers true exactly when the status it leaves is `.authorized`.
        case aRequestAnswersWhatItLeaves
        /// An undetermined status becomes the decision made at the prompt.
        case anUndeterminedStatusBecomesTheDecision
        /// A status already decided is unchanged by a request.
        case aDecidedStatusIsNotAskedAgain

        public var description: String {
            switch self {
            case .aRequestAnswersWhatItLeaves: "a request answers what it leaves"
            case .anUndeterminedStatusBecomesTheDecision: "an undetermined status becomes the decision"
            case .aDecidedStatusIsNotAskedAgain: "a decided status is not asked again"
            }
        }
    }

    /// A fresh authority at `status`, whose prompt is answered with `decision`.
    public let subject: @Sendable (_ status: AVAuthorizationStatus, _ decision: AVAuthorizationStatus) -> any MicrophoneAuthority

    public init(subject: @escaping @Sendable (_ status: AVAuthorizationStatus, _ decision: AVAuthorizationStatus) -> any MicrophoneAuthority) {
        self.subject = subject
    }

    static let statuses: [AVAuthorizationStatus] = [.notDetermined, .denied, .restricted, .authorized]
    static let decisions: [AVAuthorizationStatus] = [.denied, .authorized]

    public func disagreements(with statement: Statement) async -> [String] {
        var disagreements: [String] = []
        for status in Self.statuses {
            for decision in Self.decisions {
                let authority = subject(status, decision)
                let answer = await authority.requestAccess()
                let left = authority.status()
                let case_ = "from \(status.rawValue) with \(decision.rawValue) decided"
                switch statement {
                case .aRequestAnswersWhatItLeaves:
                    if answer != (left == .authorized) { disagreements.append("\(case_): answered \(answer) leaving \(left.rawValue)") }
                case .anUndeterminedStatusBecomesTheDecision:
                    if status == .notDetermined, left != decision { disagreements.append("\(case_): left \(left.rawValue)") }
                case .aDecidedStatusIsNotAskedAgain:
                    if status != .notDetermined, left != status { disagreements.append("\(case_): left \(left.rawValue)") }
                }
            }
        }
        return disagreements
    }
}
