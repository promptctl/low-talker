import Darwin
import Insertion
import LowTalkerCore

/// A notice host's semantics, stated once. Each statement runs one fresh host and says every way
/// it disagreed; nothing, when it agreed. `FakeNoticeHost` runs it, and so does
/// `InputMethodNotices.Host` on a port name of its own. [LAW:one-source-of-truth]
@MainActor
public struct NoticeHostContract {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// A notice the input method tells is heard on the main actor.
        case aNoticeToldIsHeard
        /// One host at a time: a second, while the first is open, is refused as the name taken.
        case aSecondHostIsRefused
        /// A host stopped frees its name for the next, and hears nothing after.
        case aStoppedHostFreesItsName
        /// The input method is supervised from the hosting until the stop, once, however often
        /// the stop is made.
        case theInputMethodIsSupervisedWhileHosted

        public var description: String {
            switch self {
            case .aNoticeToldIsHeard: "a notice told is heard"
            case .aSecondHostIsRefused: "a second host is refused"
            case .aStoppedHostFreesItsName: "a stopped host frees its name"
            case .theInputMethodIsSupervisedWhileHosted: "the input method is supervised while hosted"
            }
        }
    }

    /// A fresh host, and the input method in this process telling it a cursor arrived, saying no
    /// build.
    public typealias Subject = (host: any NoticeHost, tellCursorArrived: @Sendable () -> Void)

    public let subject: @MainActor () -> Subject

    public init(subject: @escaping @MainActor () -> Subject) {
        self.subject = subject
    }

    public func disagreements(with statement: Statement) async -> [String] {
        let (host, tell) = subject()
        let (heard, hearing) = AsyncStream.makeStream(of: InputMethodNotice.self)
        let supervision = Supervision()
        func hosting() async throws(PortNotHosted) -> Disposal {
            try await host.host(heard: { hearing.yield($0) }, asked: { _, _ in }, superviseInputMethod: {
                supervision.started += 1
                return { supervision.stopped += 1 }
            })
        }
        let stop: Disposal
        do throws(PortNotHosted) { stop = try await hosting() } catch { return ["the first host was refused: \(error)"] }
        defer { stop() }
        switch statement {
        case .aNoticeToldIsHeard:
            tell()
            var notices = heard.makeAsyncIterator()
            let notice = await notices.next()
            let expected = InputMethodNotice.cursorArrived(CursorArrival(pid: getpid(), build: nil))
            return notice == expected ? [] : ["told a cursor arrival, heard \(notice.map(String.init(describing:)) ?? "nothing")"]
        case .aSecondHostIsRefused:
            do throws(PortNotHosted) {
                let second = try await hosting()
                second()
                return ["a second host was hosted beside the first"]
            } catch {
                guard case .nameIsTaken = error else { return ["a second host was refused as \(error), not as the name taken"] }
                return []
            }
        case .aStoppedHostFreesItsName:
            stop()
            do throws(PortNotHosted) {
                let next = try await hosting()
                next()
                return []
            } catch { return ["a host after the stop was refused: \(error)"] }
        case .theInputMethodIsSupervisedWhileHosted:
            var disagreements: [String] = []
            if (supervision.started, supervision.stopped) != (1, 0) { disagreements.append("hosted, supervision started \(supervision.started) and stopped \(supervision.stopped)") }
            stop()
            stop()
            if (supervision.started, supervision.stopped) != (1, 1) { disagreements.append("stopped twice, supervision started \(supervision.started) and stopped \(supervision.stopped)") }
            return disagreements
        }
    }
}

/// How often the supervision was started and stopped.
@MainActor
private final class Supervision {
    var started = 0
    var stopped = 0
}
