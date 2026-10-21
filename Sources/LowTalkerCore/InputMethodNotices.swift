import Dispatch
import Identity
import Insertion
import os

/// What the input method tells the app for as long as the loop listens, on the notice port
/// the app hosts: each cursor it is given focus in, and its ending itself over its memory
/// ceiling. Its process is supervised meanwhile,
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
    public init(heard: @escaping @MainActor (InputMethodNotice) -> Void,
                superviseInputMethod: @MainActor () -> Disposal) throws(PortNotHosted) {
        let port = try NoticePort(
            queue: DispatchQueue(label: AppIdentity.hotkeyPortName),
            told: { event in Logger.hotkey.error("\(event.description, privacy: .public)") },
            heard: { [weak self] notice in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.open?.heard(notice) } }
            })
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
