import Foundation

/// Turning a raw RFC 5322 message into something the app can show.
///
/// Gmail never needed this. Its API hands over a parsed tree with the headers
/// already pulled out and each part base64url'd on its own, so `GmailService`
/// only ever had to pick the branch it wanted. IMAP hands over the message
/// exactly as it was posted, and everything Google was doing has to happen
/// here instead.
///
/// The counterpart to `MIMEBuilder`, which does all of this backwards.
///
/// What it handles, because real mail contains all of it: folded headers,
/// RFC 2047 encoded words in subjects and names, quoted-printable, base64,
/// nested multiparts, `multipart/alternative` with the plain part missing,
/// and charsets that are not UTF-8. What it does not do is decode an
/// attachment's bytes -- those are fetched on demand, by part number.
enum MIMEParser {

    // MARK: - What comes out

    struct Attachment: Sendable {
        var filename: String
        var mimeType: String
        var size: Int
        /// The IMAP part number (`2.1`), which is how it is fetched later
        /// without pulling the whole message down again.
        var section: String
        /// Inline images referenced by the HTML rather than things to save.
        var isInline: Bool
    }

    struct Parsed: Sendable {
        var headers: [String: String] = [:]
        var text: String?
        var html: String?
        var attachments: [Attachment] = []

        func header(_ name: String) -> String? { headers[name.lowercased()] }

        var subject: String { header("subject").map(decodedWords) ?? "" }
        var messageID: String? { header("message-id")?.trimmingCharacters(in: .whitespaces) }
        var inReplyTo: String? { header("in-reply-to")?.trimmingCharacters(in: .whitespaces) }
        var references: String? { header("references") }

        var from: Contact? { addresses(header("from")).first }
        var to: [Contact] { addresses(header("to")) }
        var cc: [Contact] { addresses(header("cc")) }

        var date: Date { header("date").flatMap(parseDate) ?? .now }
    }

    // MARK: - Parsing

    static func parse(_ data: Data) -> Parsed {
        let (headerBytes, bodyBytes) = split(data)
        let headers = parseHeaders(headerBytes)

        var parsed = Parsed(headers: headers)
        var collected = Collected()
        walk(
            body: bodyBytes,
            headers: headers,
            section: "1",
            isRoot: true,
            into: &collected
        )

        parsed.text = collected.text
        parsed.html = collected.html
        parsed.attachments = collected.attachments

        // A message with only an HTML part still needs readable text -- the
        // row preview, the classifier and search all read `body`, and none of
        // them want markup.
        if parsed.text == nil, let html = parsed.html {
            parsed.text = MailText.strippingHTML(html)
        }
        return parsed
    }

    private struct Collected {
        var text: String?
        var html: String?
        var attachments: [Attachment] = []
    }

    /// Walks one part, recursing into multiparts.
    ///
    /// `section` is the IMAP part number being built up as it descends, so an
    /// attachment can be fetched later without another full download.
    private static func walk(
        body: Data,
        headers: [String: String],
        section: String,
        isRoot: Bool,
        into collected: inout Collected
    ) {
        let contentType = headers["content-type"] ?? "text/plain"
        let mime = contentType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? "text/plain"

        if mime.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType) else { return }

            for (index, piece) in sections(of: body, boundary: boundary).enumerated() {
                let (childHeaderBytes, childBody) = split(piece)
                let childHeaders = parseHeaders(childHeaderBytes)
                // IMAP numbers a root message's children 1, 2, 3 and a nested
                // part's children 2.1, 2.2 -- so the root does not prefix.
                let childSection = isRoot ? "\(index + 1)" : "\(section).\(index + 1)"

                walk(
                    body: childBody,
                    headers: childHeaders,
                    section: childSection,
                    isRoot: false,
                    into: &collected
                )
            }
            return
        }

        let disposition = headers["content-disposition"] ?? ""
        let isAttachment = disposition.lowercased().contains("attachment")
            || parameter("filename", in: disposition) != nil
            || parameter("name", in: contentType) != nil

        if isAttachment {
            let name = parameter("filename", in: disposition)
                ?? parameter("name", in: contentType)
                ?? "attachment"
            collected.attachments.append(Attachment(
                filename: decodedWords(name),
                mimeType: mime,
                // The encoded length is what is known without downloading it.
                // Base64 runs about a third larger than the bytes it carries.
                size: headers["content-transfer-encoding"]?.lowercased().contains("base64") == true
                    ? body.count * 3 / 4
                    : body.count,
                section: section,
                isInline: disposition.lowercased().contains("inline")
                    || headers["content-id"] != nil
            ))
            return
        }

        let decoded = decode(
            body,
            encoding: headers["content-transfer-encoding"] ?? "7bit",
            charset: parameter("charset", in: contentType) ?? "utf-8"
        )

        // First one wins. `multipart/alternative` puts the plain part first
        // and the richest last, and taking the last HTML but the first text is
        // what every mail client does.
        if mime == "text/html" {
            collected.html = collected.html ?? decoded
        } else if mime.hasPrefix("text/") {
            collected.text = collected.text ?? decoded
        }
    }

    // MARK: - Headers

    /// Splits at the first blank line.
    ///
    /// Tolerates bare LF as well as CRLF: the spec says CRLF, and a
    /// surprising number of servers and mailing lists do not.
    private static func split(_ data: Data) -> (headers: Data, body: Data) {
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            return (data[..<range.lowerBound], data[range.upperBound...])
        }
        if let range = data.range(of: Data("\n\n".utf8)) {
            return (data[..<range.lowerBound], data[range.upperBound...])
        }
        return (data, Data())
    }

    /// Header names lowercased, values unfolded, duplicates joined.
    private static func parseHeaders(_ data: Data) -> [String: String] {
        // Headers are ASCII by spec; anything else in them is encoded words,
        // which are decoded later. Latin-1 maps every byte to something, so
        // nothing is lost on the way through.
        let raw = String(decoding: data, as: UTF8.self).isEmpty && !data.isEmpty
            ? String(data: data, encoding: .isoLatin1) ?? ""
            : String(decoding: data, as: UTF8.self)

        var headers: [String: String] = [:]
        var name: String?
        var value = ""

        func commit() {
            guard let key = name?.lowercased() else { return }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // References and Received legitimately repeat; a second Subject is
            // malformed and the first is the one to trust.
            if let existing = headers[key] {
                headers[key] = existing + " " + trimmed
            } else {
                headers[key] = trimmed
            }
            name = nil
            value = ""
        }

        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            // A folded continuation: still the previous header.
            if line.first == " " || line.first == "\t" {
                value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            commit()
            guard let colon = line.firstIndex(of: ":") else { continue }
            name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            value = String(line[line.index(after: colon)...])
        }
        commit()
        return headers
    }

    /// A `; name=value` parameter, quoted or bare.
    static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let wanted = name.lowercased() + "="
            guard trimmed.lowercased().hasPrefix(wanted) else { continue }

            var value = String(trimmed.dropFirst(wanted.count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    // MARK: - Bodies

    private static func decode(_ data: Data, encoding: String, charset: String) -> String {
        let bytes: Data
        switch encoding.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            bytes = Data(
                base64Encoded: String(decoding: data, as: UTF8.self)
                    .components(separatedBy: .whitespacesAndNewlines)
                    .joined(),
                options: [.ignoreUnknownCharacters]
            ) ?? data
        case "quoted-printable":
            bytes = quotedPrintable(data)
        default:
            bytes = data
        }
        return string(from: bytes, charset: charset)
    }

    /// `=E2=82=AC` back to bytes, and `=` at end of line meaning "not really a
    /// line break".
    static func quotedPrintable(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)

        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            guard byte == UInt8(ascii: "=") else {
                out.append(byte)
                index = data.index(after: index)
                continue
            }

            let first = data.index(after: index)
            guard first < data.endIndex else { break }

            // A soft line break: the "=" and the newline both disappear.
            if data[first] == UInt8(ascii: "\r") {
                let second = data.index(after: first)
                index = second < data.endIndex && data[second] == UInt8(ascii: "\n")
                    ? data.index(after: second)
                    : second
                continue
            }
            if data[first] == UInt8(ascii: "\n") {
                index = data.index(after: first)
                continue
            }

            let second = data.index(after: first)
            guard second < data.endIndex,
                  let value = UInt8(String(decoding: [data[first], data[second]], as: UTF8.self), radix: 16)
            else {
                out.append(byte)
                index = first
                continue
            }
            out.append(value)
            index = data.index(after: second)
        }
        return out
    }

    /// Bytes to text, in whatever the part said it was written in.
    static func string(from data: Data, charset: String) -> String {
        let encoding: String.Encoding
        switch charset.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii", "": encoding = .utf8
        case "iso-8859-1", "latin1", "latin-1":        encoding = .isoLatin1
        case "iso-8859-2":                             encoding = .isoLatin2
        case "windows-1252", "cp1252":                 encoding = .windowsCP1252
        case "windows-1251", "cp1251":                 encoding = .windowsCP1251
        case "koi8-r":                                 encoding = .koi8r
        case "shift_jis", "shift-jis", "sjis":         encoding = .shiftJIS
        case "euc-jp":                                 encoding = .japaneseEUC
        case "iso-2022-jp":                            encoding = .iso2022JP
        case "gb2312", "gbk", "gb18030":               encoding = .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5":                                   encoding = .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default:                                       encoding = .utf8
        }

        if let text = String(data: data, encoding: encoding) { return text }
        // A part that lied about its charset, or was truncated mid-character.
        // Latin-1 always succeeds, and mojibake beats an empty message.
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// Splits a multipart body on its boundary.
    private static func sections(of body: Data, boundary: String) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        var pieces: [Data] = []
        var searchFrom = body.startIndex
        var partStart: Int?

        while let hit = body.range(of: marker, in: searchFrom..<body.endIndex) {
            if let start = partStart {
                // Back off the CRLF that belongs to the boundary rather than
                // to the part, or every part gains a trailing blank line.
                var end = hit.lowerBound
                if end > start, body[body.index(before: end)] == UInt8(ascii: "\n") { end = body.index(before: end) }
                if end > start, body[body.index(before: end)] == UInt8(ascii: "\r") { end = body.index(before: end) }
                pieces.append(body[start..<end])
            }

            // `--boundary--` closes the multipart; nothing after it counts.
            let afterMarker = hit.upperBound
            let isClosing = afterMarker < body.endIndex
                && body[afterMarker] == UInt8(ascii: "-")
            if isClosing { break }

            var next = afterMarker
            if next < body.endIndex, body[next] == UInt8(ascii: "\r") { next = body.index(after: next) }
            if next < body.endIndex, body[next] == UInt8(ascii: "\n") { next = body.index(after: next) }

            partStart = next
            searchFrom = next
        }
        return pieces
    }

    // MARK: - Encoded words

    /// `=?UTF-8?B?SGVsbG8=?=` and its quoted-printable twin, anywhere in a
    /// header value.
    ///
    /// Subjects and display names are full of these the moment somebody writes
    /// in anything but English, and a client that skips them shows the
    /// encoding instead of the words.
    static func decodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }

        var out = ""
        var rest = Substring(value)

        while let start = rest.range(of: "=?") {
            out += rest[rest.startIndex..<start.lowerBound]
            let afterStart = rest[start.upperBound...]

            // charset ? encoding ? text ?=
            let pieces = afterStart.split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
            guard pieces.count >= 3, pieces[1].count == 1 else {
                out += "=?"
                rest = afterStart
                continue
            }

            let charset = String(pieces[0])
            let kind = pieces[1].uppercased()
            let encoded = String(pieces[2])

            let bytes: Data?
            if kind == "B" {
                bytes = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters])
            } else if kind == "Q" {
                // In a header, "_" is a space. Only here -- not in a body.
                bytes = quotedPrintable(Data(encoded.replacingOccurrences(of: "_", with: " ").utf8))
            } else {
                bytes = nil
            }

            guard let bytes else {
                out += "=?"
                rest = afterStart
                continue
            }

            out += string(from: bytes, charset: charset)

            // Step past the closing "?=" of this word.
            if let close = afterStart.range(of: "?=", range: (pieces[0].endIndex..<afterStart.endIndex)) {
                var after = afterStart[close.upperBound...]
                // Whitespace between two adjacent encoded words is not part of
                // the text and is dropped, which is what keeps a long split
                // subject from gaining spaces in the middle of words.
                if after.hasPrefix(" "), after.dropFirst().hasPrefix("=?") {
                    after = after.dropFirst()
                }
                rest = after
            } else {
                rest = afterStart[afterStart.endIndex...]
            }
        }

        out += rest
        return out
    }

    // MARK: - Addresses

    /// `Ada Lovelace <ada@example.com>, "Byron, A" <a@b.com>`
    static func addresses(_ value: String?) -> [Contact] {
        guard let value, !value.isEmpty else { return [] }

        var out: [Contact] = []
        var current = ""
        var inQuotes = false
        var inAngles = false

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !piece.isEmpty, let contact = contact(from: piece) else { return }
            out.append(contact)
        }

        for character in value {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "<" where !inQuotes: inAngles = true; current.append(character)
            case ">" where !inQuotes: inAngles = false; current.append(character)
            // A comma inside a quoted name is part of the name, not a separator.
            case "," where !inQuotes && !inAngles: flush()
            default: current.append(character)
            }
        }
        flush()
        return out
    }

    private static func contact(from piece: String) -> Contact? {
        if let open = piece.lastIndex(of: "<"), let close = piece.lastIndex(of: ">"), open < close {
            let email = String(piece[piece.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(piece[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            name = decodedWords(name)
            guard !email.isEmpty else { return nil }
            return Contact(name: name.isEmpty ? email : name, address: email.lowercased())
        }

        let bare = piece.trimmingCharacters(in: .whitespaces)
        guard bare.contains("@") else { return nil }
        return Contact(name: bare, address: bare.lowercased())
    }

    // MARK: - Dates

    /// RFC 5322: `Tue, 15 Nov 1994 12:45:26 +0100`, with the many ways real
    /// senders get it slightly wrong.
    static func parseDate(_ value: String) -> Date? {
        let cleaned = value
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss zzz",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
