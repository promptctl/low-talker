import Foundation
import OSLog

/// The composed messages this process has logged under `category` since `since`, each once.
///
/// Read on a thread of its own: the store answers through a synchronous call to logd that
/// takes seconds, and a task waiting in it holds a thread of the cooperative pool, which on the
/// three-core CI runner is a third of it (sampled, PR #223). Filtered by the predicate rather
/// than in Swift, which is most of what the read costs.
///
/// Under the parallel suite the store hands one entry back twice, about one read in seven: the
/// same date to the tenth of a microsecond, the same thread, the same message, a measured wait
/// included (low-unfiled-50ff.88w). Kept once by that identity, so a line logged once is read once.
/// The entries' dates read about 30 ms behind `Date.now` (2026-11-11), so a `date >= since`
/// filter would drop the lines a test has just logged.
public func loggedLines(category: String, since: Date) async throws -> [String] {
    try await onAThreadOfItsOwn {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        var read = Set<Entry>()
        return try store.getEntries(at: store.position(date: since), matching: NSPredicate(format: "category == %@", category))
            // A category's entries are its log lines: nothing in this program signposts.
            .map { Entry($0 as! OSLogEntryLog) }
            .filter { read.insert($0).inserted }
            .map(\.message)
    }
}

/// One entry, told from every other by when, where, and what it said.
private struct Entry: Hashable {
    let date: Date
    let thread: UInt64
    let message: String

    init(_ entry: OSLogEntryLog) {
        (date, thread, message) = (entry.date, entry.threadIdentifier, entry.composedMessage)
    }
}
