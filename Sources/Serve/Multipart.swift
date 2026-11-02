import Foundation

/// One field of a multipart/form-data body (RFC 7578): its name, the filename a file part
/// carries, and its bytes.
struct FormField: Sendable, Equatable {
    let name: String
    let filename: String?
    let value: Data

    /// The fields of `body`, in order, split on the boundary `contentType` names.
    static func parse(_ body: Data, contentType: String?) throws(APIError) -> [FormField] {
        guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else {
            throw .malformed("the body must be multipart/form-data, not \(contentType ?? "untyped")")
        }
        guard let boundary = parameter("boundary", in: contentType), !boundary.isEmpty else {
            throw .malformed("the multipart content-type names no boundary")
        }
        // Every delimiter but the first follows a line break, so one is put before the
        // first too and the body splits on a single separator.
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let pieces = split(Data("\r\n".utf8) + body, on: delimiter)
        // The piece before the first delimiter is the preamble, and the piece that opens
        // with "--" follows the closing one; everything between is a field.
        guard let closing = pieces.firstIndex(where: { $0.starts(with: Data("--".utf8)) }), closing > 0 else {
            throw .malformed("the multipart body has no closing boundary")
        }
        return try pieces[1..<closing].map { piece throws(APIError) in try field(piece) }
    }

    /// `data` cut at every `separator`, empty pieces kept. Searched with Foundation's
    /// `range(of:)` rather than the generic `split(separator:)`, which compared an upload
    /// byte by byte through generic code and held a thread for seconds in a debug build -
    /// enough to starve the CI runner's cooperative pool (low-unfiled-50ff.cis).
    private static func split(_ data: Data, on separator: Data) -> [Data] {
        var pieces: [Data] = []
        var start = data.startIndex
        while let found = data.range(of: separator, in: start..<data.endIndex) {
            pieces.append(data[start..<found.lowerBound])
            start = found.upperBound
        }
        pieces.append(data[start..<data.endIndex])
        return pieces
    }

    private static func field(_ piece: Data) throws(APIError) -> FormField {
        let blank = Data("\r\n\r\n".utf8)
        // A field opens with the line break that ends its delimiter line.
        guard piece.starts(with: Data("\r\n".utf8)), let split = piece.firstRange(of: blank) else {
            throw .malformed("a multipart field has no header block")
        }
        let head = try RequestHead.fields(piece[piece.startIndex + 2..<split.lowerBound])
        guard let disposition = head["content-disposition"], let name = parameter("name", in: disposition) else {
            throw .malformed("a multipart field has no content-disposition name")
        }
        return FormField(name: name, filename: parameter("filename", in: disposition), value: Data(piece[split.upperBound...]))
    }

    /// The value of `name=value` or `name="value"` among a header's `;`-separated parameters.
    /// A `;` inside quotes is part of a value, as in `filename="take;1.mp3"`.
    static func parameter(_ name: String, in header: String) -> String? {
        var quoted = false
        let pieces = header.split { character in
            if character == "\"" { quoted.toggle() }
            return character == ";" && !quoted
        }
        return pieces.dropFirst().lazy.compactMap { piece -> String? in
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { return nil }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            return value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
        }.first
    }
}
