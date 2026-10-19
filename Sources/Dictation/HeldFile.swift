import Foundation
import LowTalkerCore

/// What is held, kept in one file as a record of its own.
///
/// [LAW:locality-or-seam] The file is the record's shape, not `Held`'s: a later build that
/// reshapes `Held` changes the parse below, and still reads what an earlier one wrote.
public struct HeldFile: HeldStore, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The app's: Application Support, which App Sandbox puts inside the app's container, so
    /// it outlives an upgrade.
    public static let app = HeldFile(url: .applicationSupportDirectory.appending(components: "low-talker", "held.json"))

    /// No file is nothing held. One that cannot be read is moved aside, so no write replaces
    /// the words in it, and the error says where it went.
    public func read() throws(HeldUnreadable) -> Held? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw keptAside(why: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(HeldRecord.self, from: data).held()
        } catch {
            throw keptAside(why: "\(error)")
        }
    }

    /// Writes `held`, or removes the file when nothing is held. A write that fails removes
    /// the file it could not replace, since an unlink needs no free space and an older state
    /// left there would be offered at the next launch.
    public func write(_ held: Held?) throws(HeldUnkept) {
        switch held {
        case nil:
            do { try remove() } catch { throw .stale(why: error.localizedDescription) }
        case let held?:
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(HeldRecord(held)).write(to: url, options: .atomic)
            } catch {
                do { try remove() } catch let removal {
                    throw .stale(why: "\(error.localizedDescription); the older file could not be removed: \(removal.localizedDescription)")
                }
                throw .lost(why: error.localizedDescription)
            }
        }
    }

    private func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already nothing kept.
        }
    }

    private func keptAside(why: String) -> HeldUnreadable {
        let aside = url.deletingLastPathComponent().appending(path: "held-unreadable-\(Date.now.ISO8601Format()).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return HeldUnreadable(why: why, kept: .movedTo(aside.path))
        } catch {
            return HeldUnreadable(why: why, kept: .notMoved(error.localizedDescription))
        }
    }
}

/// The facts the file keeps, each decoded if present, so a field a later build adds leaves
/// the file an earlier one wrote readable.
struct HeldRecord: Codable, Equatable {
    /// The words no cursor took.
    var unplaced: Transcript?
    /// Why the latest of them were held.
    var warning: String?
    /// The words that may have landed, which stand until placed or dismissed.
    var unaccounted: Transcript?
    /// Why they may have.
    var unaccountedWarning: String?

    init(unplaced: Transcript? = nil, warning: String? = nil, unaccounted: Transcript? = nil, unaccountedWarning: String? = nil) {
        self.unplaced = unplaced
        self.warning = warning
        self.unaccounted = unaccounted
        self.unaccountedWarning = unaccountedWarning
    }

    init(_ held: Held) {
        self.init(unplaced: held.offered?.words, warning: held.offered?.warning, unaccounted: held.standing?.words, unaccountedWarning: held.standing?.warning)
    }

    /// [LAW:parse-dont-validate] The one place a record becomes `Held`: each part whole or
    /// absent, its words said, and at least one part.
    func held() throws(Unfitting) -> Held {
        func part(_ words: Transcript?, _ warning: String?) throws(Unfitting) -> Held.Part? {
            switch (words, warning) {
            case (nil, nil): return nil
            case let (words?, warning?):
                guard let part = Held.Part(words: words, warning: warning) else { throw Unfitting(record: self) }
                return part
            default: throw Unfitting(record: self)
            }
        }
        guard let held = Held(unplaced: try part(unplaced, warning), unaccounted: try part(unaccounted, unaccountedWarning)) else { throw Unfitting(record: self) }
        return held
    }

    /// Fields that fit no `Held`.
    struct Unfitting: Error, CustomStringConvertible {
        let record: HeldRecord

        var description: String {
            let present = [("unplaced", record.unplaced != nil), ("warning", record.warning != nil), ("unaccounted", record.unaccounted != nil), ("unaccountedWarning", record.unaccountedWarning != nil)]
            let fields = present.filter(\.1).map(\.0)
            return "a held record with \(fields.isEmpty ? "no fields" : fields.joined(separator: ", ")) fits nothing held"
        }
    }
}
