import Insertion
import LowTalkerCore

extension NoMicrophone: WordFree {}
extension SerialQueueError: WordFree {}

// An enum whose cases could one day carry the words names each case, so a case added
// to it does not compile until it has said what it carries.

extension InsertFailure: Accounted {
    public var account: Account {
        switch self {
        case .refused, .notYetTaken, .unreachable, .answererUnreadable, .buildMismatch: Account(facts: description)
        }
    }
}

/// The engine was not there for a press: its model failed to load, or something else holds it.
///
/// Word-free whatever its cause: the engine is asked for before it is handed any of the
/// press's audio, so nothing it says can be a reading of what was dictated.
public struct EngineUnavailable: WordFree {
    public let cause: any Error

    public init(_ cause: any Error) {
        self.cause = cause
    }

    public var description: String { "\(cause)" }
}
