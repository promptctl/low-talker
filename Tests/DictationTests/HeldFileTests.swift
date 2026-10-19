import Dictation
import Foundation
import LowTalkerCore
import Testing

/// The file the app keeps what is held in, in a directory of its own.
@MainActor
final class HeldFileTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "held-\(UUID())")
    var file: HeldFile { HeldFile(url: directory.appending(path: "held.json")) }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated static let held: [Held] = [
        .unplaced(Transcript(words: [Transcript.Word(text: " hello", time: 0.12...0.48, confidence: 0.73), Transcript.Word(text: " there.", time: 0.5...0.9, confidence: 0.91)]), warning: "refused"),
        .unplaced(Transcript(typed: "a"), warning: "refused", unaccounted: "may have landed"),
        .unaccounted(warning: "may have landed"),
    ]

    @Test(arguments: held) func whatIsWrittenIsReadBack(_ held: Held) throws {
        try file.write(held)
        #expect(try file.read() == held)
    }

    /// Nothing held is no file, and removing a file that is not there is nothing to fail at.
    @Test func nothingHeldIsNoFile() throws {
        try file.write(.unaccounted(warning: "u"))
        try file.write(nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(try file.read() == nil)
        try file.write(nil)
    }

    @Test(arguments: ["not json", #"{"warning":"refused"}"#])
    func aFileThatCannotBeReadIsMovedWhereNoWriteReplacesIt(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
        let error = try #require(throws: HeldUnreadable.self) { try file.read() }
        guard case .movedTo(let path) = error.kept else {
            Issue.record("left in place: \(error)")
            return
        }
        #expect(try Data(contentsOf: URL(filePath: path)) == Data(text.utf8))
        #expect(try file.read() == nil)
    }

    /// A file as this build writes it, so a change to `Transcript` that a later build could not
    /// read it with fails here rather than at the upgrade.
    @Test func aFileAsThisBuildWritesItReads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"unplaced":{"words":[{"text":" hello","time":[0.12,0.48],"confidence":0.73}]},"warning":"refused"}"#.utf8).write(to: file.url)
        #expect(try file.read() == .unplaced(Transcript(words: [Transcript.Word(text: " hello", time: 0.12...0.48, confidence: 0.73)]), warning: "refused"))
    }

    /// A field this build does not know is one a later build added, and the rest still reads.
    @Test func aFieldALaterBuildAddsLeavesTheFileReadable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"unaccounted":"may have landed","mayHaveLanded":{"words":[]}}"#.utf8).write(to: file.url)
        #expect(try file.read() == .unaccounted(warning: "may have landed"))
    }

    /// A write that fails removes what stood at the path, so no older state is offered at the
    /// next launch: here a directory the atomic rename cannot replace, and removal can.
    @Test func aWriteThatFailsLeavesNothingKept() throws {
        try FileManager.default.createDirectory(at: file.url.appending(path: "in-the-way"), withIntermediateDirectories: true)
        let error = try #require(throws: HeldUnkept.self) { try file.write(.unaccounted(warning: "u")) }
        guard case .lost = error else {
            Issue.record("not lost: \(error)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    /// A write that cannot remove the older file either says the older state still stands.
    @Test(arguments: [Held?.some(.unaccounted(warning: "newer")), nil])
    func aWriteThatCannotRemoveTheOlderFileSaysItStands(_ held: Held?) throws {
        try file.write(.unaccounted(warning: "older"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let error = #expect(throws: HeldUnkept.self) { try file.write(held) }
        guard case .stale? = error else {
            Issue.record("not stale: \(String(describing: error))")
            return
        }
        #expect(try file.read() == .unaccounted(warning: "older"))
    }
}
