import CryptoKit
import DarwinCalls
import Darwin
import Foundation
import Security

/// Who a process is, as the kernel vouches for it.
///
/// The one check both ends of the channel make. The input method asks it of every request,
/// because needing no grant is the point of this delivery and a door that types for anyone
/// who knocks is the whole of the exposure; the app asks it of every answer, because a name
/// anyone can compute is a name anyone can register first. [LAW:single-enforcer]
///
/// **Read from the kernel, never from disk.** The input method is sandboxed, and the
/// sandbox refuses it the sender's executable, which is what `SecCodeCheckValidity` and
/// `SecTaskValidateForRequirement` both read - measured on low-input-method-s71.6tk: each
/// fails with EPERM for every sender, so a check built on them refuses the app too. The
/// kernel holds the signature it validated the running code against, and hands it over by
/// audit token to a sandboxed caller. So the signature comes from there: its code directory
/// has to hash to the cdhash the kernel reports for that process, which makes it the running
/// code's own, and its CMS signature has to verify over that code directory, which makes the
/// certificate inside it the one that signed what is running. [FRAMING:representation]
///
/// The audit token and never the pid: a pid can be reused between being read and being
/// checked, and the check would then be of whichever process inherited the number.
public enum PeerIdentity: Equatable, Codable, Sendable, CustomStringConvertible {
    /// Signed by a certificate: the identifier the code is signed as, and the SHA-1 of the
    /// certificate in lowercase hex - what a code signing requirement's
    /// `certificate leaf = H"..."` names.
    case signed(identifier: String, certificate: String)
    /// Signed ad hoc. No certificate vouches for it, so it is nobody but exactly the code it
    /// runs, named by the cdhash the kernel runs it under. An identifier here would be a
    /// claim anyone can sign, so there is none. [LAW:types-are-the-program] Nothing that
    /// ships admits one - the app and the input method each require the other `signed` -
    /// so it is what a stranger is named as in a refusal, and what the suite's own ad hoc
    /// runner is admitted as.
    case adHoc(cdhash: String)

    public var description: String {
        switch self {
        case let .signed(identifier, certificate): "\(identifier) signed by certificate \(certificate)"
        case let .adHoc(cdhash): "code signed ad hoc with cdhash \(cdhash)"
        }
    }

    /// Why a process's identity could not be read.
    public enum Unreadable: Error, Equatable, Sendable, CustomStringConvertible {
        /// The kernel would not answer `operation` about the process: it has exited, or the
        /// token never named one.
        case kernelRefused(operation: String, errno: Int32)
        /// This process's own audit token could not be read, so it cannot say who it is.
        case noAuditToken(kern_return_t)
        /// The kernel no longer holds the process's code valid.
        case notValid
        /// Signed by a certificate but not under the hardened runtime, so anything could
        /// have been loaded into it and its signature says nothing about what it runs.
        case notHardened
        /// This process is signed ad hoc, so there is no certificate for a peer to share.
        case noCertificate
        case signatureMalformed(String)
        /// The certificate's signature does not verify over the code directory.
        case signatureDoesNotVerify(String)
        /// The signature's primary code directory - the one its CMS signature covers - is not
        /// the one the kernel runs the process under. A signature whose kernel cdhash comes
        /// from an alternate directory is refused this way too, since binding the certificate
        /// to an alternate is more than this check proves. [LAW:no-silent-failure]
        case notTheRunningCode

        public var description: String {
            switch self {
            case let .kernelRefused(operation, errno):
                "the kernel would not say \(operation) of the process: \(String(cString: strerror(errno)))"
            case .noAuditToken(let status): "this process's audit token could not be read: \(Mach.describe(status))"
            case .notValid: "the kernel no longer holds the process's code signature valid"
            case .notHardened: "the process is signed but not under the hardened runtime, so code could have been loaded into it that its signature does not cover"
            case .noCertificate: "this process is signed ad hoc, so there is no certificate for its peer to be signed by; build it signed (make app)"
            case .signatureMalformed(let why): "the process's code signature is malformed: \(why)"
            case .signatureDoesNotVerify(let why): "the process's code signature does not verify: \(why)"
            case .notTheRunningCode: "the process's signed code directory is not the one it is running under"
            }
        }
    }

    /// Why a process was not admitted.
    public enum NotAdmitted: Error, Equatable, Sendable, CustomStringConvertible {
        case unidentified(Unreadable)
        case someoneElse(PeerIdentity)

        public var description: String {
            switch self {
            case .unidentified(let why): "\(why)"
            case .someoneElse(let identity): "it is \(identity)"
            }
        }
    }

    /// The identity of the process `token` names.
    public static func of(_ token: audit_token_t) throws(Unreadable) -> PeerIdentity {
        var token = token
        var status: UInt32 = 0
        try kernel("its status", &token, operation: CS_OPS_STATUS, into: &status, size: 4)
        guard status & UInt32(CS_VALID) != 0 else { throw .notValid }
        var cdhash = [UInt8](repeating: 0, count: 20)
        try kernel("its cdhash", &token, operation: CS_OPS_CDHASH, into: &cdhash, size: 20)
        let signature = try Signature(Data(try blob(&token)))
        guard try signature.cdhash() == cdhash else { throw .notTheRunningCode }
        guard let cms = signature.cms else { return .adHoc(cdhash: hex(cdhash)) }
        guard status & UInt32(CS_RUNTIME) != 0 else { throw .notHardened }
        return .signed(identifier: signature.identifier, certificate: try signature.signer(cms))
    }

    /// This process's own identity.
    public static func ofThisProcess() throws(Unreadable) -> PeerIdentity {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard read == KERN_SUCCESS else { throw .noAuditToken(read) }
        return try of(token)
    }

    /// `identifier`, signed by the certificate that signed this process.
    ///
    /// **Off the caller's actor**, always. Reading this process's own signature runs a trust
    /// evaluation (`Signature.signer`) that Security faults - "should not be called on the main
    /// thread" - when it runs on an app's main thread over a Developer ID signature, a dozen
    /// times a launch. `@concurrent` moves it onto the concurrent executor so no caller has to
    /// remember to; this is the one place that obligation lives. [LAW:single-enforcer]
    ///
    /// [LAW:one-source-of-truth] The certificate is read off this process's own signature
    /// rather than compiled in. The app and its input method are signed together - by the
    /// dev identity `make signing-identity` makes, or by the Developer ID that ships them -
    /// so "whoever signed me" is true of every build without anyone writing it down, and a
    /// copy left over from a build signed by another certificate is refused rather than
    /// believed.
    @concurrent public static func signedLikeThisProcess(identifier: String) async throws(Unreadable) -> PeerIdentity {
        guard case .signed(_, let certificate) = try ofThisProcess() else { throw .noCertificate }
        return .signed(identifier: identifier, certificate: certificate)
    }

    /// Admits the process `token` names when it is this identity, or throws who it is.
    func admits(_ token: audit_token_t) throws(NotAdmitted) {
        let found: PeerIdentity
        do throws(Unreadable) { found = try .of(token) } catch { throw .unidentified(error) }
        guard found == self else { throw .someoneElse(found) }
    }

    private static func kernel(
        _ what: String, _ token: inout audit_token_t, operation: Int32,
        into buffer: UnsafeMutableRawPointer, size: Int
    ) throws(Unreadable) {
        guard csops_audittoken(token.pid, UInt32(operation), buffer, size, &token) == 0 else {
            throw .kernelRefused(operation: what, errno: errno)
        }
    }

    /// The process's whole signature. Asked for once with room for its header alone, which
    /// the kernel refuses with ERANGE after writing the header, whose length says how much
    /// room the whole needs.
    private static func blob(_ token: inout audit_token_t) throws(Unreadable) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 8)
        if csops_audittoken(token.pid, UInt32(CS_OPS_BLOB), &header, header.count, &token) != 0, errno != ERANGE {
            throw .kernelRefused(operation: "its signature", errno: errno)
        }
        var blob = [UInt8](repeating: 0, count: max(Int(bigEndian: header, at: 4), header.count))
        try kernel("its signature", &token, operation: CS_OPS_BLOB, into: &blob, size: blob.count)
        return blob
    }
}

/// A code signature as the kernel holds it: a superblob of indexed blobs, big-endian
/// throughout, of which two matter here - the code directory and the CMS signature over it.
private struct Signature {
    let codeDirectory: Data
    let identifier: String
    /// The CMS signature, or nil when the code is signed ad hoc and carries none.
    let cms: Data?

    init(_ blob: Data) throws(PeerIdentity.Unreadable) {
        let bytes = [UInt8](blob)
        guard bytes.count >= 12, Int(bigEndian: bytes, at: 0) == Int(CSMAGIC_EMBEDDED_SIGNATURE) else {
            throw .signatureMalformed("it is not an embedded signature")
        }
        var directory: [UInt8]?
        var cms: [UInt8]?
        for index in 0 ..< Int(bigEndian: bytes, at: 8) {
            let entry = 12 + index * 8
            guard entry + 8 <= bytes.count else { throw .signatureMalformed("its index runs past its end") }
            let offset = Int(bigEndian: bytes, at: entry + 4)
            guard offset + 8 <= bytes.count else { throw .signatureMalformed("a blob starts past its end") }
            let length = Int(bigEndian: bytes, at: offset + 4)
            guard length >= 8, offset + length <= bytes.count else { throw .signatureMalformed("a blob runs past its end") }
            switch Int(bigEndian: bytes, at: entry) {
            // The primary code directory, the one the CMS signature covers.
            case Int(CSSLOT_CODEDIRECTORY): directory = Array(bytes[offset ..< offset + length])
            // The CMS signature, past its own eight-byte blob header.
            case Int(CSSLOT_SIGNATURESLOT): cms = Array(bytes[offset + 8 ..< offset + length])
            default: break
            }
        }
        guard let directory, directory.count >= 44 else { throw .signatureMalformed("it has no code directory") }
        // The identifier is a C string at the offset the directory's sixth word gives.
        let identifierAt = Int(bigEndian: directory, at: 20)
        guard identifierAt < directory.count, let end = directory[identifierAt...].firstIndex(of: 0),
              let identifier = String(bytes: directory[identifierAt ..< end], encoding: .utf8)
        else { throw .signatureMalformed("its code directory names no identifier") }
        codeDirectory = Data(directory)
        self.identifier = identifier
        self.cms = cms.flatMap { $0.isEmpty ? nil : Data($0) }
    }

    /// The code directory's cdhash, by the hash its own header names: a SHA-1 is its cdhash
    /// whole, and a SHA-256 is cut to the twenty bytes the kernel keeps.
    func cdhash() throws(PeerIdentity.Unreadable) -> [UInt8] {
        switch Int(codeDirectory[codeDirectory.startIndex + 37]) {
        case Int(CS_HASHTYPE_SHA1): return Array(Insecure.SHA1.hash(data: codeDirectory))
        case Int(CS_HASHTYPE_SHA256): return Array(SHA256.hash(data: codeDirectory).prefix(20))
        case let type: throw .signatureMalformed("its code directory is hashed with type \(type), which this check does not read")
        }
    }

    /// The SHA-1 of the certificate whose signature verifies over the code directory.
    ///
    /// The signature is checked and the certificate's trust is not: nothing here asks
    /// whether any authority vouches for the certificate, because the question is whether
    /// it is one particular certificate, which comparing its hash answers exactly.
    func signer(_ cms: Data) throws(PeerIdentity.Unreadable) -> String {
        var made: CMSDecoder?
        guard CMSDecoderCreate(&made) == errSecSuccess, let decoder = made else {
            throw .signatureDoesNotVerify("no CMS decoder could be made")
        }
        let fed = cms.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard fed == errSecSuccess,
              CMSDecoderSetDetachedContent(decoder, codeDirectory as CFData) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else { throw .signatureMalformed("its CMS signature cannot be read") }
        var status = CMSSignerStatus.unsigned
        let asked = CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, nil, nil)
        guard asked == errSecSuccess, status == .valid else {
            throw .signatureDoesNotVerify("CMS signer status \(status.rawValue)")
        }
        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess, let certificate else {
            throw .signatureMalformed("its CMS signature carries no signer certificate")
        }
        return hex(Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data))
    }
}

private func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

private extension Int {
    /// The big-endian word at `offset`.
    init(bigEndian bytes: [UInt8], at offset: Int) {
        self = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
    }
}
