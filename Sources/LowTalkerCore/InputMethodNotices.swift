import Dispatch
import Identity
import Insertion
import os

/// What the input method tells and asks the app for as long as the loop listens, on the notice
/// port the app hosts: each cursor it is given focus in, its ending itself over its memory
/// ceiling, and, asked and answered, whether the app owes words to a Return it holds. Its
/// process is supervised meanwhile,
/// since nothing but the app starts it again once it has ended.
///
/// Hosting the port is also what keeps one copy of the app listening: the name is one per
/// login session, so a second copy finds it held, throws here, and its loop never starts its
/// hotkey. [LAW:single-enforcer]
///
/// [LAW:effects-at-boundaries] The supervision is the app's to bring: launching a process is
/// no part of hearing a notice.
@MainActor
public final class InputMethodNotices {
    /// The port, where a notice goes, and how the supervision stops: held together, because
    /// a notice can still be on its way to the main queue when the notices stop, and
    /// notices that have stopped tell nothing after it. [LAW:no-ambient-temporal-coupling]
    private var open: (port: NoticePort, heard: @MainActor (InputMethodNotice) -> Void, unsupervise: Disposal)?

    /// Throws when the port cannot be hosted, most often because another copy of the app
    /// already hears on it.
    /// `asked` is handed each question with the one right to answer it, on the port's own
    /// queue and not the main one: the first question is answered from there, and the second is
    /// taken to the main actor and answered when it is known.
    init(portName: String, senders: PeerIdentity,
         heard: @escaping @MainActor (InputMethodNotice) -> Void,
         asked: @escaping @Sendable (Question, any Answering) -> Void,
         superviseInputMethod: @MainActor () -> Disposal) throws(PortNotHosted) {
        let port = try NoticePort(
            portName: portName, senders: senders,
            queue: DispatchQueue(label: portName),
            told: { event in Logger.hotkey.error("\(event.description, privacy: .public)") },
            heard: { [weak self] notice in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.open?.heard(notice) } }
            },
            asked: { asked($0, $1) })
        // Supervised only once the port is hosted, so the first notice has somewhere to go.
        open = (port, heard, superviseInputMethod())
    }

    /// Closes the port here and now, so a loop rebuilt straight after hosts the name again,
    /// and stops the supervision. The process is left running: it is what every app in front
    /// talks to.
    public func stop() {
        open?.unsupervise()
        open = nil
    }
}

/// Where the input method's notices are heard: a port hosted for as long as the loop listens,
/// handing each notice to the main actor and each question with its one right to answer, and the
/// input method's process supervised from the moment it is hosted until it is stopped.
///
/// [LAW:effects-at-boundaries] Hosting a port is an effect the app is handed, so a test hosts
/// one that hears what the test tells it. `NoticeHostContract` holds the fake to `Host`.
@MainActor
public protocol NoticeHost {
    /// Hosts the port, then starts the supervision, and answers how both stop. Throws when the
    /// port cannot be hosted, and then supervises nothing.
    func host(
        heard: @escaping @MainActor (InputMethodNotice) -> Void,
        asked: @escaping @Sendable (Question, any Answering) -> Void,
        superviseInputMethod: @MainActor () -> Disposal
    ) async throws(PortNotHosted) -> Disposal
}

extension InputMethodNotices {
    /// The notices on a port of the app's, heard from the input method alone.
    public struct Host: NoticeHost {
        private let portName: String
        private let senders: @Sendable () async throws(PortNotHosted) -> PeerIdentity

        /// The app's own port, hearing the input method signed as this app is. Reading this
        /// process's signature is a seconds-long read, so it is made off the main actor, when
        /// the port is hosted. [LAW:single-enforcer]
        public init() {
            self.init(portName: AppIdentity.hotkeyPortName) { () throws(PortNotHosted) in
                do throws(PeerIdentity.Unreadable) {
                    return try await .signedLikeThisProcess(identifier: AppIdentity.inputMethodBundleIdentifier)
                } catch { throw .noRequirement(error) }
            }
        }

        /// Under a name and a requirement someone else chose, which is how a test hosts one
        /// without being the app.
        package init(portName: String, senders: @escaping @Sendable () async throws(PortNotHosted) -> PeerIdentity) {
            self.portName = portName
            self.senders = senders
        }

        public func host(
            heard: @escaping @MainActor (InputMethodNotice) -> Void,
            asked: @escaping @Sendable (Question, any Answering) -> Void,
            superviseInputMethod: @MainActor () -> Disposal
        ) async throws(PortNotHosted) -> Disposal {
            let notices = try InputMethodNotices(
                portName: portName, senders: try await senders(),
                heard: heard, asked: asked, superviseInputMethod: superviseInputMethod)
            return { notices.stop() }
        }
    }
}
