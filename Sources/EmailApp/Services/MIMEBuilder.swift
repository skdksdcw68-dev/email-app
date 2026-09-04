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

    /// A file going out with a message.
    ///
    /// The bytes are held whole, because the message is built whole: Gmail's
    /// send endpoint takes one encoded string and there is nowhere to stream
    /// into. That is the reason for `attachmentLimit` below.
    struct Attached: Equatable {
        var filename: String
        var mimeType: String
        var data: Data

        var size: Int { data.count }
    }

    /// The most that may go out with one message.
    ///
    /// Gmail's `messages.send` takes the whole email as a JSON field, which
    /// is what lets a reply carry `threadId` and land in its conversation.
    /// The cost is a request-body ceiling, and base64 inflates everything by
    /// a third on the way. Four megabytes of files is what fits under it with
    /// room for the message itself.
    ///
    /// Raising this means the resumable upload endpoint, which takes the MIME
    /// as raw bytes and has no room for `threadId`, so replies would stop
    /// threading. Not worth it until somebody actually asks.
    static let attachmentLimit = 4 * 1024 * 1024

    struct Envelope {
        var from: String
        var to: String
        var cc: String?
        var bcc: String?
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
        /// Files going with it. Empty is the common case and produces exactly
        /// the message it always did.
        var attachments: [Attached] = []
    }

    /// The complete message, base64url encoded and ready for `raw`.
    ///
    /// 🔴 **Gmail's API format, and nothing else's.** The `raw` field of a
    /// Gmail send takes the whole message base64url'd; SMTP and IMAP APPEND
    /// take the message itself. Handing this to either of those posts one long
    /// base64 blob as the body -- which is exactly what happened, and what
    /// arrived at the other end looking like a token rather than an email.
    ///
    /// For anything that is not the Gmail API, use `message(_:)`.
    static func raw(
        _ envelope: Envelope,
        boundary: String = UUID().uuidString,
        messageID: String? = nil,
        date: Date = .now
    ) -> String {
        base64url(message(envelope, boundary: boundary, messageID: messageID, date: date))
    }

    /// The message itself, before encoding. Exposed for tests.
    ///
    /// `alternativeBoundary` is only used when there are attachments *and*
    /// HTML, where the text has to be an alternative pair nested inside the
    /// mixed part. Two boundaries, because a part cannot use its parent's:
    /// the parser would end the outer part at the first inner delimiter.
    /// - Parameters:
    ///   - messageID: pinned by tests, generated for real sends. Every call
    ///     otherwise mints a new one, which is correct -- two sends are two
    ///     messages -- and makes the output non-deterministic.
    static func message(
        _ envelope: Envelope,
        boundary: String = UUID().uuidString,
        alternativeBoundary: String = UUID().uuidString,
        messageID: String? = nil,
        date: Date = .now
    ) -> String {
        var lines: [String] = [
            "From: \(envelope.from)",
            "To: \(envelope.to)",
        ]
        if let cc = envelope.cc, !cc.isEmpty {
            lines.append("Cc: \(cc)")
        }
        // Written like any other header. What makes it blind is that the
        // sending server strips it before delivery, not that it is absent
        // from the message handed over.
        if let bcc = envelope.bcc, !bcc.isEmpty {
            lines.append("Bcc: \(bcc)")
        }
        lines.append("Subject: \(encodedHeader(envelope.subject))")

        // Both required by RFC 5322, and both were missing.
        //
        // Gmail's API fills them in for its own sends, which is why nothing
        // noticed. Send the same message over SMTP and it arrives with no Date
        // and no Message-ID -- and a message with neither is close to the
        // definition of spam as far as a receiving filter is concerned. It is
        // not the only reason mail from a new domain lands in the junk folder,
        // but it is the only one this app was causing.
        lines.append("Date: \(rfc5322Date(date))")
        lines.append("Message-ID: \(messageID ?? Self.messageID(from: envelope.from))")

        if let inReplyTo = envelope.inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
            // References carries the whole chain. Falling back to In-Reply-To
            // is correct for the first reply in a thread.
            lines.append("References: \(envelope.references ?? inReplyTo)")
        }

        lines.append("MIME-Version: 1.0")

        if envelope.attachments.isEmpty {
            lines.append(contentsOf: bodySection(envelope, boundary: boundary))
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append(contentsOf: bodySection(envelope, boundary: alternativeBoundary))
            for file in envelope.attachments {
                lines.append("--\(boundary)")
                lines.append(contentsOf: attachmentPart(file))
            }
            lines.append("--\(boundary)--")
        }

        // RFC 2822 is CRLF, not LF. Gmail tolerates LF; other hops do not.
        return lines.joined(separator: "\r\n")
    }

    /// What the person wrote: one plain part, or a plain and an HTML one
    /// wrapped in a multipart/alternative.
    private static func bodySection(_ envelope: Envelope, boundary: String) -> [String] {
        guard let html = envelope.html, !html.isEmpty else {
            return partHeaders(type: "text/plain") + [base64Body(envelope.plainText)]
        }

        var lines = [
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
        ]
        lines.append(contentsOf: partHeaders(type: "text/plain"))
        lines.append(base64Body(envelope.plainText))
        lines.append("--\(boundary)")
        lines.append(contentsOf: partHeaders(type: "text/html"))
        lines.append(base64Body(html))
        // The closing delimiter takes a trailing "--". Without it the last
        // part is unterminated and some clients drop it.
        lines.append("--\(boundary)--")
        return lines
    }

    private static func attachmentPart(_ file: Attached) -> [String] {
        let name = encodedFilename(file.filename)
        let type = file.mimeType.isEmpty ? "application/octet-stream" : file.mimeType
        return [
            "Content-Type: \(type); name=\"\(name)\"",
            "Content-Disposition: attachment; filename=\"\(name)\"",
            "Content-Transfer-Encoding: base64",
            "",
            wrap(file.data.base64EncodedString(), at: 76).joined(separator: "\r\n"),
        ]
    }

    /// A filename lands inside a quoted header value, so a quote in it would
    /// end the value early and everything after would be read as more
    /// parameters. Newlines would be worse: a new header entirely.
    static func encodedFilename(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return encodedHeader(cleaned.isEmpty ? "attachment" : cleaned)
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

    /// `Tue, 15 Nov 1994 12:45:26 +0100`, in English whatever the phone is
    /// set to. A date header in another locale is not a date header.
    static func rfc5322Date(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// `<uuid@sender-domain>`.
    ///
    /// The domain has to be one the sender is actually at -- a Message-ID
    /// pointing somewhere else is itself a spam signal -- so it is taken from
    /// the From address rather than invented.
    static func messageID(from sender: String) -> String {
        let domain: String
        if let at = sender.lastIndex(of: "@") {
            domain = sender[sender.index(after: at)...]
                .prefix { $0 != ">" && $0 != " " }
                .lowercased()
        } else {
            domain = "localhost"
        }
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
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
