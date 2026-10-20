import Foundation
import os

/// What this process tells the app, in the order it happened: every cursor a controller is
/// given focus in, so the app can offer words no cursor took to the one that just arrived.
///
/// [LAW:no-shared-mutable-globals] Shared for `FocusedClient`'s reason: `IMKServer` builds
/// controllers out of a class name, so there is no constructor of ours to hand a sender to.
/// It is one stream with one writer's door, `cursorArrived(in:)`, and one reader, the
/// process's entry point, which does the sending.
public final class Notices: Sendable {
    public static let shared = Notices()

    /// One element per cursor arrival. The newest are kept if the reader falls behind, since
    /// one arrival is as good as another to the app. [LAW:no-ambient-temporal-coupling]
    public let arrivals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker-inputmethod", category: "notices")

    private init() {
        (arrivals, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// A controller was given focus in a cursor that can take words, in `application`.
    public func cursorArrived(in application: String) {
        log.info("a cursor arrived in \(application, privacy: .public)")
        continuation.yield()
    }
}
