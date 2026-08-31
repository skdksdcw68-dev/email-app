import Foundation

/// Builds the RFC 2822 message that Gmail's send endpoint wants.
///
/// Gmail does not take a JSON body with to/subject/text fields. It takes one
/// `raw` string: a complete email, base64url encoded. Everything that makes
/// mail work -- non-ASCII subjects, HTML alternatives, threading -- is a
/// header or a body part in that string, so this is where all of it lives.
///
/// Deliberately pure string building with no networking, so it can be tested
/// exhaustively. The one thing that must not be wrong is the encoding.
enum MIMEBuilder {

    struct Envelope {
        var from: String
        var to: String
        var cc: String?
        var subject: String
        /// Always present. A message with only an HTML part is a spam signal
        /// and unreadable in plain-text clients.
        var plainText: String
        /// When set, the message goes out as multipart/alternative.
        var html: String?
        /// The `Message-ID` of the message being replied to, angle brackets
        /// included. Gmail threads on its own threadId, but every other client
        /// in the chain threads on these.
        var inReplyTo: String?
        var references: String?
    }

    /// The complete message, base64url encoded and ready for `raw`.
    static func raw(_ envelope: Envelope, boundary: String = UUID().uuidString) -> String {
        base64url(message(envelope, boundary: boundary))
    }

    /// The message itself, before encoding. Exposed for tests.
    static func message(_ envelope: Envelope, boundary: String = UUID().uuidString) -> String {
        var lines: [String] = [
            "From: \(envelope.from)",
            "To: \(envelope.to)",
        ]
        if let cc = envelope.cc, !cc.isEmpty {
            lines.append("Cc: \(cc)")
        }
        lines.append("Subject: \(encodedHeader(envelope.subject))")

        if let inReplyTo = envelope.inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
            // References carries the whole chain. Falling back to In-Reply-To
            // is correct for the first reply in a thread.
            lines.append("References: \(envelope.references ?? inReplyTo)")
        }

        lines.append("MIME-Version: 1.0")

        if let html = envelope.html, !html.isEmpty {
            lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append(contentsOf: partHeaders(type: "text/plain"))
            lines.append(base64Body(envelope.plainText))
            lines.append("--\(boundary)")
            lines.append(contentsOf: partHeaders(type: "text/html"))
            lines.append(base64Body(html))
            // The closing delimiter takes a trailing "--". Without it the last
            // part is unterminated and some clients drop it.
            lines.append("--\(boundary)--")
        } else {
            lines.append(contentsOf: partHeaders(type: "text/plain"))
            lines.append(base64Body(envelope.plainText))
        }

        // RFC 2822 is CRLF, not LF. Gmail tolerates LF; other hops do not.
        return lines.joined(separator: "\r\n")
    }

    private static func partHeaders(type: String) -> [String] {
        [
            "Content-Type: \(type); charset=\"UTF-8\"",
            // base64 sidesteps the 998-character line limit and every
            // quoted-printable escaping question in one move.
            "Content-Transfer-Encoding: base64",
            "",
        ]
    }

    // MARK: - Encoding

    /// A header value that is pure ASCII goes as-is. Anything else has to be
    /// an RFC 2047 encoded-word, or the subject arrives as mojibake.
    static func encodedHeader(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.allSatisfy({ $0.isASCII }) else {
            let encoded = Data(cleaned.utf8).base64EncodedString()
            return "=?UTF-8?B?\(encoded)?="
        }
        return cleaned
    }

    /// base64 wrapped at 76 characters, as the spec requires.
    static func base64Body(_ text: String) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        return wrap(encoded, at: 76).joined(separator: "\r\n")
    }

    static func wrap(_ text: String, at width: Int) -> [String] {
        guard width > 0, !text.isEmpty else { return [text] }
        var lines: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(String(text[index..<end]))
            index = end
        }
        return lines
    }

    /// Gmail wants base64url, not standard base64: URL-safe alphabet and no
    /// padding. Sending standard base64 fails with a 400 that does not say so.
    static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `Name <address>` when there is a name worth showing, bare address
    /// otherwise. A name containing a comma or a quote has to be quoted or it
    /// reads as two recipients.
    static func address(name: String, email: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != email else { return email }
        let needsQuoting = trimmed.contains(where: { ",;<>\"".contains($0) })
        let display = needsQuoting
            ? "\"\(trimmed.replacingOccurrences(of: "\"", with: ""))\""
            : trimmed
        return "\(display) <\(email)>"
    }
}
