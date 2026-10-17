import Foundation

/// Just enough MIME to pull attachments out of an email or an HTML form upload.
enum MIME {
    struct Attachment {
        let filename: String
        let data: Data
    }

    /// All parts with a filename, at any depth (emails nest multipart/alternative etc.).
    static func attachments(in entity: Data) -> [Attachment] {
        var found: [Attachment] = []
        collect(entity, into: &found)
        return found
    }

    private static func collect(_ entity: Data, into found: inout [Attachment]) {
        let (headerData, body) = splitHeaders(entity)
        let headers = parseHeaders(headerData)
        let contentType = headers["content-type"] ?? "text/plain"

        if contentType.lowercased().hasPrefix("multipart/"),
           let boundary = parameter("boundary", in: contentType) {
            for part in multipartParts(body, boundary: boundary) {
                collect(part, into: &found)
            }
            return
        }

        let disposition = headers["content-disposition"] ?? ""
        guard let rawName = parameter("filename", in: disposition) ?? parameter("name", in: contentType),
              !rawName.isEmpty else { return }  // form fields, message text, empty file inputs

        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let data: Data
        switch encoding {
        case "base64": data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable": data = decodeQuotedPrintable(body)
        default: data = body
        }
        guard !data.isEmpty else { return }
        found.append(Attachment(filename: decodeEncodedWords(rawName), data: data))
    }

    /// Splits at the first blank line.
    static func splitHeaders(_ entity: Data) -> (Data, Data) {
        for sep in ["\r\n\r\n", "\n\n"] {
            if let r = entity.range(of: Data(sep.utf8)) {
                return (entity[entity.startIndex..<r.lowerBound], entity[r.upperBound...])
            }
        }
        return (entity, Data())
    }

    /// Header names lowercased; folded continuation lines joined.
    static func parseHeaders(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var headers: [String: String] = [:]
        var lastKey: String?
        // Note: Swift treats "\r\n" as one Character, so normalise line endings before splitting.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", let key = lastKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                lastKey = key
            }
        }
        return headers
    }

    /// Value of `name=...` in a header like `form-data; name="photo"; filename="a.jpg"`.
    /// Handles quoted values and RFC 2231 `filename*=UTF-8''a%20b.jpg`.
    static func parameter(_ name: String, in header: String) -> String? {
        var params: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var pieces: [String] = []
        for ch in header {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { pieces.append(current); current = "" } else { current.append(ch) }
        }
        pieces.append(current)
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            params[key] = value
        }
        let key = name.lowercased()
        if let extended = params[key + "*"] {
            // charset'language'percent-encoded
            let parts = extended.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            let encoded = parts.count == 3 ? String(parts[2]) : extended
            return encoded.removingPercentEncoding ?? encoded
        }
        return params[key]
    }

    /// The parts between `--boundary` delimiter lines.
    static func multipartParts(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var positions: [Range<Data.Index>] = []
        var searchFrom = body.startIndex
        while let r = body.range(of: delimiter, in: searchFrom..<body.endIndex) {
            // Only count delimiters at the start of a line.
            if r.lowerBound == body.startIndex || body[r.lowerBound - 1] == UInt8(ascii: "\n") {
                positions.append(r)
            }
            searchFrom = r.upperBound
        }

        var parts: [Data] = []
        for (i, r) in positions.enumerated() where i + 1 < positions.count {
            var partStart = r.upperBound
            // The rest of the delimiter line ("--" marks the end; otherwise CRLF).
            if body[partStart...].starts(with: Data("--".utf8)) { break }
            while partStart < body.endIndex, body[partStart] != UInt8(ascii: "\n") { partStart += 1 }
            partStart = min(partStart + 1, body.endIndex)

            var partEnd = positions[i + 1].lowerBound
            if partEnd > partStart, body[partEnd - 1] == UInt8(ascii: "\n") { partEnd -= 1 }
            if partEnd > partStart, body[partEnd - 1] == UInt8(ascii: "\r") { partEnd -= 1 }
            if partEnd > partStart { parts.append(body.subdata(in: partStart..<partEnd)) }
        }
        return parts
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        let bytes = [UInt8](data)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l); i += 3; continue
                }
                // Soft line break: "=\r\n" or "=\n"
                if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\n") { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "\r"), bytes[i + 2] == UInt8(ascii: "\n") { i += 3; continue }
            }
            out.append(b); i += 1
        }
        return out
    }

    /// Decodes RFC 2047 words like `=?UTF-8?B?cGhvdG8uanBn?=` that some mail apps use for filenames.
    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: s),
                  let kind = Range(match.range(at: 2), in: s),
                  let text = Range(match.range(at: 3), in: s) else { continue }
            let payload = String(s[text])
            let decoded: Data?
            if s[kind].lowercased() == "b" {
                decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
            } else {
                decoded = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            if let decoded, let str = String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .isoLatin1) {
                result.replaceSubrange(whole, with: str)
            }
        }
        return result
    }
}
