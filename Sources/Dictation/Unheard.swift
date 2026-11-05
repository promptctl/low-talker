import Foundation
import LowTalkerCore

/// One press's speech that no engine heard: the model failed to load under the press, so what was
/// said exists only as the samples the microphone delivered.
///
/// [LAW:types-are-the-program] Samples and the vocabulary's terms as spelled, not an engine's
/// reading: the pipeline is audio, then words, then placed, and this is the first stage. `Hold`
/// owns the words from the second on.
public struct UnheardSpeech: Sendable, Equatable {
    public let said: Date
    /// The terms of the mode's vocabulary the speech was said under, as spelled.
    public let vocabulary: [String]
    public let samples: [Float]

    public init(said: Date, vocabulary: [String], samples: [Float]) {
        self.said = said
        self.vocabulary = vocabulary
        self.samples = samples
    }

    public var seconds: TimeInterval { AudioClip.duration(for: samples.count) }
}

/// What a store says of one kept speech without its samples, which are read one at a time.
public struct UnheardEntry: Sendable, Equatable, Hashable {
    /// The store's name for it, which is how it is read and removed.
    public let id: String
    public let said: Date
    public let seconds: TimeInterval
    public let vocabulary: [String]

    public init(id: String, said: Date, seconds: TimeInterval, vocabulary: [String]) {
        self.id = id
        self.said = said
        self.seconds = seconds
        self.vocabulary = vocabulary
    }
}

/// Why kept speech could not be kept, read or removed, in the words of whatever refused.
public struct UnheardFault: Error, Equatable, Sendable, CustomStringConvertible {
    public let why: String

    public init(_ why: String) { self.why = why }

    public var description: String { why }
}

/// What a store holds when it is opened: the speech it can read, oldest first, and a line for
/// each file it could not, which it moved aside so no later write replaces it.
public struct UnheardRead: Sendable, Equatable {
    public let entries: [UnheardEntry]
    public let setAside: [String]

    public init(entries: [UnheardEntry], setAside: [String] = []) {
        self.entries = entries
        self.setAside = setAside
    }
}

/// Where speech no engine heard is kept until one has, so a quit, crash or upgrade between the
/// press and the engine does not lose it.
public protocol UnheardStore: Sendable {
    func entries() -> UnheardRead
    func keep(_ speech: UnheardSpeech) throws(UnheardFault) -> UnheardEntry
    func samples(of entry: UnheardEntry) throws(UnheardFault) -> [Float]
    func remove(_ entry: UnheardEntry) throws(UnheardFault)
}

/// The store as files: one per press in a directory of its own, beside the held words, which in the
/// app is inside the App Sandbox container and so outlives an upgrade.
///
/// A file is a line of JSON, then the samples as raw 32-bit floats; the line says how many, so a file
/// cut short is read as unreadable and not as shorter speech.
public struct UnheardFiles: UnheardStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's: beside `held.json`.
    public static let app = UnheardFiles(directory: .applicationSupportDirectory.appending(components: "low-talker", "unheard"))

    private struct Header: Codable {
        let said: Date
        let vocabulary: [String]
        let samples: Int
    }

    private static let suffix = ".speech"
    private static let newline = UInt8(ascii: "\n")
    /// More than any header is long: a line of terms is a few kilobytes at the most.
    private static let headerReach = 1 << 20

    public func entries() -> UnheardRead {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(Self.suffix) }.sorted()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return UnheardRead(entries: [])
        } catch {
            return UnheardRead(entries: [], setAside: ["the folder of kept speech could not be listed: \(error.localizedDescription)"])
        }
        var entries: [UnheardEntry] = []
        var setAside: [String] = []
        for name in names {
            do {
                entries.append(try entry(named: name))
            } catch {
                setAside.append(keptAside(name, why: error.why))
            }
        }
        return UnheardRead(entries: entries, setAside: setAside)
    }

    public func keep(_ speech: UnheardSpeech) throws(UnheardFault) -> UnheardEntry {
        let name = "\(Int(speech.said.timeIntervalSince1970 * 1000))-\(UUID().uuidString)\(Self.suffix)"
        let header = Header(said: speech.said, vocabulary: speech.vocabulary, samples: speech.samples.count)
        do {
            var data = try JSONEncoder().encode(header)
            data.append(Self.newline)
            speech.samples.withUnsafeBytes { data.append(contentsOf: $0) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: name), options: .atomic)
        } catch {
            throw UnheardFault(error.localizedDescription)
        }
        return UnheardEntry(id: name, said: speech.said, seconds: speech.seconds, vocabulary: speech.vocabulary)
    }

    public func samples(of entry: UnheardEntry) throws(UnheardFault) -> [Float] {
        let data: Data
        do { data = try Data(contentsOf: directory.appending(path: entry.id)) } catch { throw UnheardFault(error.localizedDescription) }
        guard let end = data.firstIndex(of: Self.newline) else { throw UnheardFault("the file has no header") }
        let header = try header(of: data.prefix(upTo: end))
        let body = data.suffix(from: end + 1)
        guard body.count == header.samples * MemoryLayout<Float>.size else {
            throw UnheardFault("the file holds \(body.count) bytes of samples where its header says \(header.samples)")
        }
        return body.withUnsafeBytes { raw in (0..<header.samples).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) } }
    }

    public func remove(_ entry: UnheardEntry) throws(UnheardFault) {
        do {
            try FileManager.default.removeItem(at: directory.appending(path: entry.id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone.
        } catch {
            throw UnheardFault(error.localizedDescription)
        }
    }

    /// The file's header and size, read without its samples, which are most of it.
    private func entry(named name: String) throws(UnheardFault) -> UnheardEntry {
        let url = directory.appending(path: name)
        let head: Data
        let size: Int
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            head = try handle.read(upToCount: Self.headerReach) ?? Data()
            size = Int(try handle.seekToEnd())
        } catch {
            throw UnheardFault(error.localizedDescription)
        }
        guard let end = head.firstIndex(of: Self.newline) else { throw UnheardFault("the file has no header") }
        let header = try header(of: head.prefix(upTo: end))
        guard size - (end + 1) == header.samples * MemoryLayout<Float>.size else {
            throw UnheardFault("the file is \(size - (end + 1)) bytes of samples where its header says \(header.samples) samples")
        }
        return UnheardEntry(id: name, said: header.said, seconds: AudioClip.duration(for: header.samples), vocabulary: header.vocabulary)
    }

    private func header(of line: Data) throws(UnheardFault) -> Header {
        do { return try JSONDecoder().decode(Header.self, from: line) } catch { throw UnheardFault("the header is unreadable: \(error)") }
    }

    /// Moves a file that could not be read out of the listing, so nothing is written over it and
    /// it is not tried again, and says where it went.
    private func keptAside(_ name: String, why: String) -> String {
        let aside = directory.appending(path: "\(name).unreadable")
        do {
            try FileManager.default.moveItem(at: directory.appending(path: name), to: aside)
            return "kept speech in \(name) could not be read (\(why)); it was moved to \(aside.path)"
        } catch {
            return "kept speech in \(name) could not be read (\(why)), and could not be moved aside: \(error.localizedDescription)"
        }
    }
}
