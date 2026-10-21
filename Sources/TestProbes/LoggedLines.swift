import Foundation
import OSLog

/// The composed messages this process has logged under `category` since `since`.
///
/// Read on a thread of its own: the store answers through a synchronous call to logd that
/// takes seconds, and a task waiting in it holds a thread of the cooperative pool, which on the
/// three-core CI runner is a third of it (sampled, PR #223). Filtered by the predicate rather
/// than in Swift, which is most of what the read costs.
public func loggedLines(category: String, since: Date) async throws -> [String] {
    try await onAThreadOfItsOwn {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: since), matching: NSPredicate(format: "category == %@", category))
            .map(\.composedMessage)
    }
}
