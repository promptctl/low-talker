import CryptoKit
import Darwin
import Foundation
@testable import Insertion
import DarwinCalls
import Security
import Testing

/// The real port, answering as the input method would and admitting this process, on a
/// queue of its own.
///
/// A queue and not the test's own thread, because the real port lives across a process
/// boundary and a port serviced by the sender's own thread cannot show what that costs: a
/// handler that takes too long would hold the very thread that is supposed to notice it
/// took too long, and the timeout under test could never fire. [LAW:behavior-not-structure]
func hostInsertion(name: String, answer: @escaping @Sendable (InsertRequest) -> InsertionAnswer) throws -> InsertionPort {
    try InsertionPort(
        portName: name, senders: try OwnProcess.identity(), build: aBuild, queue: DispatchQueue(label: name),
        told: { Issue.record("the port was told \($0)") }, answer: answer)
}

/// The app's end, believing only this process.
func inserter(_ name: String, timeout: Duration = aBudgetTheRunnerCannotSpend) throws -> InputMethodInserter {
    InputMethodInserter(portName: name, timeout: timeout, answerer: .success(try OwnProcess.identity()), build: aBuild)
}

/// The build the suite plays on both ends. Any values at all: what is under test is that the
/// two ends agree or do not, never which build either is.
let aBuild = Build(number: "1", revision: "0123456789ab")

/// Sends `payload` to the port on `name` by hand and returns the bytes it answered, for the
/// cases that put something on the wire no `Inserter` would. Blocking: call it from a
/// thread of its own.
func roundTrip(_ payload: Data, to name: String) throws -> Data {
    var remote = mach_port_t()
    try #require(lt_bootstrap_look_up(name, &remote) == KERN_SUCCESS)
    defer { mach_port_deallocate(mach_task_self_, remote) }
    let reply = try ReceiveRight(sendable: false)
    let sent = Mach.send(
        payload, id: 0, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
        replyTo: reply.port, timeout: aBudgetTheRunnerCannotSpend)
    try #require(sent == MACH_MSG_SUCCESS)
    guard case .received(let answer) = Mach.receive(on: reply.port, timeout: aBudgetTheRunnerCannotSpend) else {
        throw NoAnswer()
    }
    return try #require(answer.payload)
}

private struct NoAnswer: Error {}

/// This process, as the one peer whose identity a test can hold without building a signed
/// app: its real signature, read the way the channel reads every peer - which, for the
/// runner `swift test` hosts the suite in, is ad hoc. [LAW:one-source-of-truth]
/// Read here and nowhere else, so every case that plays the app or the input method plays
/// the same one.
enum OwnProcess {
    static func identity() throws -> PeerIdentity { try PeerIdentity.ofThisProcess() }
}

/// `insertion-probe`, the sender that is not this process.
enum Probe {
    /// Built beside this suite's bundle, since the suite depends on it. Signed ad hoc, as
    /// SwiftPM links every binary.
    static func url() throws -> URL {
        let url = Bundle(for: Seen.self).bundleURL.deletingLastPathComponent().appending(path: "insertion-probe")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "no insertion-probe beside the suite")
        return url
    }

    /// A copy of the probe signed as `identifier` by the dev identity, and the identity the
    /// kernel will read off it. The dev identity is the one `make signing-identity` makes,
    /// which `make test` makes ready first; it is a real certificate, which no ad hoc signature
    /// can stand in for. [LAW:verifiable-goals]
    static func signed(as identifier: String, hardened: Bool = true) async throws -> (url: URL, identity: PeerIdentity, certificate: String) {
        try await onAThreadOfItsOwn { try signing(as: identifier, hardened: hardened) }
    }

    private static func signing(as identifier: String, hardened: Bool) throws -> (url: URL, identity: PeerIdentity, certificate: String) {
        let copy = FileManager.default.temporaryDirectory.appending(path: "insertion-probe-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: try url(), to: copy)
        // The caller removes the copy it is handed; one that never reaches it is removed here.
        do { return try sign(copy, as: identifier, hardened: hardened) } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
    }

    private static func sign(_ copy: URL, as identifier: String, hardened: Bool) throws -> (url: URL, identity: PeerIdentity, certificate: String) {
        let name = try run(repository.appending(path: "scripts/signing-identity"), []).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["--force", "--sign", name, "--identifier", identifier] + (hardened ? ["--options", "runtime"] : []) + [copy.path])
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(copy as CFURL, [], &code) == errSecSuccess)
        var information: CFDictionary?
        try #require(SecCodeCopySigningInformation(try #require(code), SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
        let signing = try #require(information as? [CFString: Any])
        let leaf = try #require((signing[kSecCodeInfoCertificates] as? [SecCertificate])?.first)
        let certificate = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return (copy, .signed(identifier: identifier, certificate: certificate), certificate)
    }

    /// Runs the probe at `url` against the port on `name` and returns the line it printed.
    static func send(
        _ text: String, to name: String, answeredBy answerer: PeerIdentity, from url: URL? = nil
    ) async throws -> String {
        let probe = try url ?? self.url()
        let answering = String(decoding: try JSONEncoder().encode(answerer), as: UTF8.self)
        let playing = String(decoding: try JSONEncoder().encode(aBuild), as: UTF8.self)
        return try await onAThreadOfItsOwn { try run(probe, [name, answering, playing, text]) }
    }

    /// Runs `executable` to completion and returns what it printed, trimmed. Blocking: call
    /// it from a thread of its own.
    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repository
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(executable.lastPathComponent) exited \(process.terminationStatus)")
        return String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// What a hosted port saw, across the queue it saw it on.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: InsertRequest?

    func record(_ request: InsertRequest) {
        lock.lock()
        seen = request
        lock.unlock()
    }

    var request: InsertRequest? {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var text: String? { request?.text }
}

/// What a hosted port read of its sender, across the queue it read it on.
final class Read: @unchecked Sendable {
    private let lock = NSLock()
    private var read: Result<PeerIdentity, PeerIdentity.Unreadable>?

    func record(_ result: Result<PeerIdentity, PeerIdentity.Unreadable>) {
        lock.lock()
        read = result
        lock.unlock()
    }

    var result: Result<PeerIdentity, PeerIdentity.Unreadable>? {
        lock.lock()
        defer { lock.unlock() }
        return read
    }
}

/// What a hosted port was told, across the queue it was told on.
final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var told: [InsertionPort.Event] = []

    func record(_ event: InsertionPort.Event) {
        lock.lock()
        told.append(event)
        lock.unlock()
    }

    var events: [InsertionPort.Event] {
        lock.lock()
        defer { lock.unlock() }
        return told
    }
}

/// Runs `body` on a thread of the test's own and awaits what it returned or threw.
///
/// For the cases that send or wait by hand rather than through `Inserter`'s awaited
/// overload: a test body runs on the cooperative pool, and a blocking call there holds one
/// of its threads for the whole wait. Measured: four blocking calls held every thread of a
/// three-core runner and no other test ran.
/// [LAW:no-ambient-temporal-coupling]
func onAThreadOfItsOwn<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

/// A port name no other test, no repeat of this one, and no installed input method answers
/// on.
///
/// Unique per call and not per case, because a released port does not wait: a case whose
/// far end is still inside an answer when the case returns leaves its name held until that
/// answer finishes, and `#function` with `getpid()` are the same two values on the next pass
/// through the same case in the same process. A rerun would then be refused `nameIsTaken`
/// by its own previous run. [LAW:no-ambient-temporal-coupling]
func aPortNobodyElseUses(_ note: String = #function) -> String {
    "ai.promptctl.low-talker.test.insert.\(abs(note.hashValue)).\(getpid()).\(UUID().uuidString)"
}
