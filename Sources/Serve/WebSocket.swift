import CryptoKit
import Foundation

/// RFC 6455 as a server speaks it: the handshake's answer, and frames read from a client
/// and written to one. No extension is agreed, so a client that offers permessage-deflate
/// (Pipecat does) sends and receives every frame uncompressed.
enum WebSocket {
    /// The upgrade a websocket request asked for, answered: the 101 and its accept key.
    static func handshake(_ head: RequestHead) throws(APIError) -> Data {
        guard head.method == "GET" else { throw .notFound(method: head.method, path: head.path) }
        guard head.headers["upgrade"]?.lowercased() == "websocket" else {
            throw .malformed("\(head.path) is a websocket; the request did not ask to upgrade to one")
        }
        guard head.headers["sec-websocket-version"] == "13" else {
            throw .malformed("sec-websocket-version is \(head.headers["sec-websocket-version"] ?? "missing"), not 13")
        }
        guard let key = head.headers["sec-websocket-key"], !key.isEmpty else { throw .malformed("the upgrade has no sec-websocket-key") }
        return Data((
            "HTTP/1.1 101 Switching Protocols\r\n"
                + "upgrade: websocket\r\n"
                + "connection: Upgrade\r\n"
                + "sec-websocket-accept: \(accept(key))\r\n\r\n"
        ).utf8)
    }

    /// The key's answer, which proves to the client that the server read its upgrade.
    static func accept(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    enum Opcode: UInt8, Sendable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA

        var isControl: Bool { rawValue & 0x8 != 0 }
    }

    /// One frame as the client sent it, unmasked.
    struct Frame: Equatable, Sendable {
        let final: Bool
        let opcode: Opcode
        let payload: Data
    }

    /// A frame a server sends: whole, unmasked.
    static func frame(_ opcode: Opcode, _ payload: Data) -> Data {
        var head = Data([0x80 | opcode.rawValue])
        switch payload.count {
        case ..<126: head.append(UInt8(payload.count))
        case ..<65536: head.append(126); head.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).bigEndian, Array.init))
        default: head.append(127); head.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
        }
        return head + payload
    }

    /// The close frame for `code`, with `reason` after it.
    static func close(_ code: UInt16, _ reason: String = "") -> Data {
        frame(.close, Data(withUnsafeBytes(of: code.bigEndian, Array.init)) + Data(reason.utf8))
    }

    /// The first frame in `bytes` and how many bytes it took, or nil while it is not all
    /// there yet. `limit` bounds a payload, so a length field cannot make the server wait
    /// on, or hold, more than that.
    ///
    /// [LAW:parse-dont-validate] A frame in hand came from a client (it was masked), uses
    /// no extension, and is a control frame only if it is whole and short.
    static func parse(_ data: Data, limit: Int) throws(Violation) -> (Frame, consumed: Int)? {
        // The head is at most 14 bytes; the payload is read out of `data` only once it is all there.
        let bytes = [UInt8](data.prefix(14))
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] & 0x70 == 0 else { throw Violation(code: 1002, "a frame set a reserved bit, and no extension was agreed") }
        guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { throw Violation(code: 1002, "opcode \(bytes[0] & 0x0F) is not one RFC 6455 defines") }
        guard bytes[1] & 0x80 != 0 else { throw Violation(code: 1002, "a client frame came unmasked") }
        let final = bytes[0] & 0x80 != 0
        let lengthBytes = switch bytes[1] & 0x7F {
        case 126: 2
        case 127: 8
        default: 0
        }
        let maskAt = 2 + lengthBytes
        guard bytes.count >= maskAt + 4 else { return nil }
        let length = lengthBytes == 0 ? UInt64(bytes[1] & 0x7F) : bytes[2..<maskAt].reduce(0) { $0 << 8 | UInt64($1) }
        guard !opcode.isControl || (final && length <= 125) else { throw Violation(code: 1002, "a control frame was fragmented or over 125 bytes") }
        guard length <= UInt64(limit) else { throw Violation(code: 1009, "a frame of \(length) bytes is over the \(limit) byte limit") }
        let start = maskAt + 4
        let end = start + Int(length)
        guard data.count >= end else { return nil }
        let mask = (bytes[maskAt], bytes[maskAt + 1], bytes[maskAt + 2], bytes[maskAt + 3])
        // Unmasked in place through a buffer: a generic map over the payload's bytes held a
        // thread for seconds per streamed second of audio in a debug build, which starved the
        // CI runner's cooperative pool (low-unfiled-50ff.cis).
        var payload = Data(data[data.startIndex + start..<data.startIndex + end])
        payload.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for offset in 0..<buffer.count {
                switch offset % 4 {
                case 0: buffer[offset] ^= mask.0
                case 1: buffer[offset] ^= mask.1
                case 2: buffer[offset] ^= mask.2
                default: buffer[offset] ^= mask.3
                }
            }
        }
        return (Frame(final: final, opcode: opcode, payload: payload), end)
    }

    /// What a client said: a data message whole, however many frames carried it, or a
    /// control frame, which may arrive between a message's fragments.
    enum Message: Equatable, Sendable {
        case text(String)
        case binary(Data)
        /// The close frame's code, or nil when it carried none.
        case close(UInt16?)
        case ping(Data)
        case pong
    }

    /// Fragments gathered into messages.
    struct Assembler {
        private var open: (opcode: Opcode, payload: Data)?

        /// The message `frame` completes, or nil when it is one more fragment of one.
        mutating func take(_ frame: Frame, limit: Int) throws(Violation) -> Message? {
            let (opcode, payload): (Opcode, Data)
            switch (frame.opcode, open) {
            case (.close, _): return .close(try closeCode(frame.payload))
            case (.ping, _): return .ping(frame.payload)
            case (.pong, _): return .pong
            case (.continuation, nil): throw Violation(code: 1002, "a continuation frame came with no message to continue")
            case (.continuation, let started?): (opcode, payload) = (started.opcode, started.payload + frame.payload)
            case (.text, nil), (.binary, nil): (opcode, payload) = (frame.opcode, frame.payload)
            case (.text, _?), (.binary, _?): throw Violation(code: 1002, "a new message began before the last one's final fragment")
            }
            guard payload.count <= limit else { throw Violation(code: 1009, "a message of over \(limit) bytes") }
            guard frame.final else {
                open = (opcode, payload)
                return nil
            }
            open = nil
            guard opcode == .text else { return .binary(payload) }
            guard let text = String(data: payload, encoding: .utf8) else { throw Violation(code: 1007, "a text message is not UTF-8") }
            return .text(text)
        }
    }

    /// The code a close frame's payload opens with, refused when it is not one a peer may
    /// send (RFC 6455 7.4) or its reason is not UTF-8.
    private static func closeCode(_ payload: Data) throws(Violation) -> UInt16? {
        guard !payload.isEmpty else { return nil }
        guard payload.count >= 2 else { throw Violation(code: 1002, "a close frame's code was one byte") }
        let code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
        guard sendable.contains(where: { $0.contains(code) }) else { throw Violation(code: 1002, "close code \(code) is not one a peer may send") }
        guard String(data: payload.dropFirst(2), encoding: .utf8) != nil else { throw Violation(code: 1007, "a close frame's reason is not UTF-8") }
        return code
    }

    /// The close codes a peer may put on the wire: the registered ones other than those
    /// that only ever describe a close (1004 to 1006, 1015), and those left to libraries
    /// and applications.
    private static let sendable: [ClosedRange<UInt16>] = [1000...1003, 1007...1014, 3000...4999]

    /// A client broke the protocol: the close code that says how, and why in words.
    struct Violation: Error, Equatable, CustomStringConvertible {
        let code: UInt16
        let description: String

        init(code: UInt16, _ description: String) {
            self.code = code
            self.description = description
        }
    }
}
