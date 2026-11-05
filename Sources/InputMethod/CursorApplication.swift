/// Which app a client's cursor belongs to, as the person using it would say: the one they are
/// looking at, which is not always the one whose process the client answers for.
///
/// A sandboxed app's Open and Save panels are drawn by an XPC service, so the client of
/// their name field names `com.apple.appkit.xpc.openAndSavePanelService` while the app in
/// front stays the one that put the panel up (measured on studious, low-reliability-z2z.sk9:
/// Installer in front, the service's client in its Open panel). Comparing the service's own
/// identifier with the front app would refuse every word dictated into such a panel, and
/// naming the cursor for the service would bind a dictation's later words to an app that is
/// never in front. So the cursor is named for the app that was in front when the service's
/// client took focus, which is the panel's host, and every later question about the cursor -
/// is its app still in front, did that app quit, which app did the words go to - is asked
/// of that.
///
/// Decided here, in the one place a cursor is named, so nothing past it needs to know a
/// service was ever involved. [LAW:parse-dont-validate] [LAW:single-enforcer]
nonisolated enum CursorApplication {
    /// The service that draws Open and Save panels.
    static let panelService = "com.apple.appkit.xpc.openAndSavePanelService"

    /// The app a client named `client` belongs to while `frontmost` is in front, or nil when
    /// none can be told: no name, or the panel service with no other app in front to be its
    /// host. Every other client is the app it says it is.
    static func named(by client: String?, inFront frontmost: String?) -> String? {
        guard let client, !client.isEmpty else { return nil }
        guard client == panelService else { return client }
        guard let frontmost, !frontmost.isEmpty, frontmost != panelService else { return nil }
        return frontmost
    }
}
