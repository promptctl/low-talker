import Foundation
import LowTalkerCore

/// What is held, kept in one file as a record of its own.
///
/// [LAW:locality-or-seam] The file is the record's shape, not `Held`'s: a later build that
/// reshapes `Held` changes the parse below, and still reads what an earlier release wrote.
public struct HeldFile: HeldStore, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The app's: Application Support, which App Sandbox puts inside the app's container, so
    /// it outlives an upgrade.
    public static let app = HeldFile(url: .applicationSupportDirectory.appending(components: "low-talker", "held.json"))

    /// No file is nothing held or dismissed. One that cannot be read is moved aside, so no
    /// write replaces the words in it, and the error says where it went.
    public func read() throws(HeldUnreadable) -> HoldState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return HoldState()
        } catch {
            throw keptAside(why: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(HoldRecord.self, from: data).state()
        } catch {
            throw keptAside(why: "\(error)")
        }
    }

    /// Writes `state`, or removes the file when nothing is held or dismissed. A write that
    /// fails removes the file it could not replace, since an unlink needs no free space and an
    /// older state left there would be offered at the next launch.
    public func write(_ state: HoldState) throws(HeldUnkept) {
        switch state {
        case HoldState():
            do { try remove() } catch { throw .stale(why: error.localizedDescription) }
        default:
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(HoldRecord(state)).write(to: url, options: .atomic)
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

/// The file's record: what is held, in the fields an earlier release wrote at the top level, so
/// its files still read, and what the person dismissed last, in a record of its own.
struct HoldRecord: Codable, Equatable {
    var held: HeldRecord
    var dismissed: HeldRecord?

    init(_ state: HoldState) {
        held = state.held.map { HeldRecord($0) } ?? HeldRecord()
        dismissed = state.dismissed.map { HeldRecord($0) }
    }

    private enum Key: CodingKey {
        case dismissed
    }

    init(from decoder: any Decoder) throws {
        held = try HeldRecord(from: decoder)
        dismissed = try decoder.container(keyedBy: Key.self).decodeIfPresent(HeldRecord.self, forKey: .dismissed)
    }

    func encode(to encoder: any Encoder) throws {
        try held.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(dismissed, forKey: .dismissed)
    }

    /// [LAW:parse-dont-validate] The one place the file becomes a `HoldState`: each record fits
    /// a `Held` or nothing, and the file keeps at least one, since an empty state is no file.
    func state() throws(HeldRecord.Unfitting) -> HoldState {
        let state = HoldState(held: try held.held(), dismissed: try dismissed?.held())
        guard state != HoldState() else { throw HeldRecord.Unfitting(record: held) }
        return state
    }
}

/// The facts kept of one `Held`, each decoded if present, so a field a later build adds leaves
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
    /// absent, its words said. A record with neither part is nothing held.
    func held() throws(Unfitting) -> Held? {
        func part(_ words: Transcript?, _ warning: String?) throws(Unfitting) -> Held.Part? {
            switch (words, warning) {
            case (nil, nil): return nil
            case let (words?, warning?):
                guard let part = Held.Part(words: words, warning: warning) else { throw Unfitting(record: self) }
                return part
            default: throw Unfitting(record: self)
            }
        }
        return Held(unplaced: try part(unplaced, warning), unaccounted: try part(unaccounted, unaccountedWarning))
    }

    /// Fields that fit no `Held`.
    struct Unfitting: Error, CustomStringConvertible {
        let record: HeldRecord

        var description: String {
            let present = [("unplaced", record.unplaced != nil), ("warning", record.warning != nil), ("unaccounted", record.unaccounted != nil), ("unaccountedWarning", record.unaccountedWarning != nil)]
            let fields = present.filter(\.1).map(\.0)
            return "a held record with \(fields.isEmpty ? "no fields" : fields.joined(separator: ", ")) fits nothing held or dismissed"
        }
    }
}
