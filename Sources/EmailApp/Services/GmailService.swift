import Foundation

/// Reads Gmail directly from the device.
///
/// Deliberately no server in the path. CASA's trigger is an app with "the
/// ability to access data from or through a third-party server", so keeping
/// mail on the phone is a materially lower risk profile as well as less to
/// build. If background sync forces a backend later, `MailStore.connect()`
/// stays the seam.
///
/// Scopes requested are the minimum for read + draft:
///   gmail.readonly   read and classify
///   gmail.compose    create drafts, send
/// Not gmail.modify, and certainly not mail.google.com.
enum GmailService {
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
    ]

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    enum ServiceError: LocalizedError {
        case http(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "Gmail returned \(code). \(body)"
            case .malformed: "Gmail returned something unexpected."
            }
        }
    }

    // MARK: - Fetching

    /// One page of inbox mail, newest first, plus the cursor for the next one.
    ///
    /// Gmail paginates and will not hand over a whole mailbox at once. Without
    /// carrying `nextPageToken` forward the app could only ever show the newest
    /// `limit` messages, which is exactly what it did.
    struct Page {
        let messages: [Message]
        /// `nil` once the mailbox is exhausted.
        let nextPageToken: String?
    }

    /// Gmail's own search syntax, used to bound the initial import. Three
    /// months is enough to be genuinely useful offline without pulling a
    /// decade of mail down a phone connection.
    static let importWindow = "newer_than:3m"

    /// Recent inbox mail, newest first.
    static func fetchInbox(
        accessToken: String,
        limit: Int = 25,
        pageToken: String? = nil,
        query: String? = nil,
        label: String = "INBOX"
    ) async throws -> Page {
        let (ids, next) = try await messageIDs(
            accessToken: accessToken,
            limit: limit,
            pageToken: pageToken,
            query: query,
            label: label
        )

        // Fetch details concurrently but keep the fan-out modest; Gmail's
        // per-user rate limit is generous, not infinite.
        var byID: [String: Message] = [:]
        try await withThrowingTaskGroup(of: (String, Message?).self) { group in
            for id in ids {
                group.addTask {
                    (id, try? await fetchMessage(id: id, accessToken: accessToken))
                }
            }
            for try await (id, message) in group {
                byID[id] = message
            }
        }

        // Restore the order the list endpoint gave us -- it is already
        // newest-first, and the task group finishes in arbitrary order.
        return Page(messages: ids.compactMap { byID[$0] }, nextPageToken: next)
    }

    private static func messageIDs(
        accessToken: String,
        limit: Int,
        pageToken: String?,
        query searchQuery: String? = nil,
        label: String = "INBOX"
    ) async throws -> ([String], String?) {
        var components = URLComponents(string: "\(base)/messages")!
        var query: [URLQueryItem] = [
            .init(name: "maxResults", value: String(limit)),
            .init(name: "labelIds", value: label),
        ]
        if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
        if let searchQuery { query.append(.init(name: "q", value: searchQuery)) }
        components.queryItems = query

        let json = try await get(components.url!, accessToken: accessToken)
        let next = json["nextPageToken"] as? String
        guard let messages = json["messages"] as? [[String: Any]] else { return ([], next) }
        return (messages.compactMap { $0["id"] as? String }, next)
    }

    private static func fetchMessage(id: String, accessToken: String) async throws -> Message {
        let url = URL(string: "\(base)/messages/\(id)?format=full")!
        let json = try await get(url, accessToken: accessToken)
        guard var message = parse(json) else { throw ServiceError.malformed }

        // Gmail returns a large body part as an attachmentId rather than inline
        // data. Without this the whole message collapses to its ~200 character
        // snippet -- which looks exactly like the app truncating long mail.
        if let payload = json["payload"] as? [String: Any],
           let deferred = deferredBody(in: payload),
           let raw = try? await fetchAttachment(
               messageID: id, attachmentID: deferred.attachmentID, accessToken: accessToken
           ) {
            message.body = (deferred.isHTML || raw.looksLikeMarkup)
                ? strippingHTML(raw)
                : raw.removingStrayMarkup()
        }

        return message
    }

    /// A body part that Gmail did not inline. Plain text wins over HTML, and
    /// this only reports a part when there was no inline data to use.
    static func deferredBody(in payload: [String: Any]) -> (attachmentID: String, isHTML: Bool)? {
        if firstPart(in: payload, mimeType: "text/plain") != nil { return nil }
        if let id = attachmentID(in: payload, mimeType: "text/plain") { return (id, false) }

        if firstPart(in: payload, mimeType: "text/html") != nil { return nil }
        if let id = attachmentID(in: payload, mimeType: "text/html") { return (id, true) }

        return nil
    }

    private static func attachmentID(in payload: [String: Any], mimeType: String) -> String? {
        if payload["mimeType"] as? String == mimeType,
           let body = payload["body"] as? [String: Any],
           let id = body["attachmentId"] as? String {
            return id
        }
        for part in payload["parts"] as? [[String: Any]] ?? [] {
            if let found = attachmentID(in: part, mimeType: mimeType) { return found }
        }
        return nil
    }

    private static func fetchAttachment(
        messageID: String, attachmentID: String, accessToken: String
    ) async throws -> String? {
        let url = URL(string: "\(base)/messages/\(messageID)/attachments/\(attachmentID)")!
        let json = try await get(url, accessToken: accessToken)
        guard let data = json["data"] as? String else { return nil }
        return decode(data)
    }

    private static func get(_ url: URL, accessToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.http(http.statusCode, String(body.prefix(200)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.malformed
        }
        return json
    }

    // MARK: - Sending

    /// Sends a message for real. `gmail.compose` covers this -- it is "manage
    /// drafts and send email" -- so no extra scope is needed.
    ///
    /// Returns Gmail's id for the sent message so the local copy can carry it.
    @discardableResult
    static func send(
        accessToken: String,
        envelope: MIMEBuilder.Envelope,
        threadID: String? = nil
    ) async throws -> (id: String, threadID: String?) {
        var payload: [String: Any] = ["raw": MIMEBuilder.raw(envelope)]
        // Passing threadId is what makes Gmail file the reply into the same
        // conversation rather than starting a new one.
        if let threadID { payload["threadId"] = threadID }

        let json = try await post(
            URL(string: "\(base)/messages/send")!,
            body: payload,
            accessToken: accessToken
        )
        guard let id = json["id"] as? String else { throw ServiceError.malformed }
        return (id, json["threadId"] as? String)
    }

    /// Writes a real Gmail draft, so it appears in Gmail on every device
    /// rather than only in this app.
    @discardableResult
    static func createDraft(
        accessToken: String,
        envelope: MIMEBuilder.Envelope,
        threadID: String? = nil
    ) async throws -> String {
        var message: [String: Any] = ["raw": MIMEBuilder.raw(envelope)]
        if let threadID { message["threadId"] = threadID }

        let json = try await post(
            URL(string: "\(base)/drafts")!,
            body: ["message": message],
            accessToken: accessToken
        )
        guard let id = json["id"] as? String else { throw ServiceError.malformed }
        return id
    }

    private static func post(
        _ url: URL,
        body: [String: Any],
        accessToken: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.http(http.statusCode, String(text.prefix(300)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.malformed
        }
        return json
    }

    // MARK: - Parsing

    static func parse(_ json: [String: Any]) -> Message? {
        guard let payload = json["payload"] as? [String: Any] else { return nil }

        let headers = (payload["headers"] as? [[String: Any]] ?? [])
            .reduce(into: [String: String]()) { result, header in
                if let name = header["name"] as? String, let value = header["value"] as? String {
                    // Header names are case-insensitive on the wire.
                    result[name.lowercased()] = value
                }
            }

        let labels = Set(json["labelIds"] as? [String] ?? [])
        let snippet = (json["snippet"] as? String)
            .map { $0.replacingOccurrences(of: "&#39;", with: "'") } ?? ""

        // internalDate is epoch milliseconds and always present -- far more
        // reliable than parsing the RFC 2822 Date header.
        let date: Date
        if let millis = json["internalDate"] as? String, let value = Double(millis) {
            date = Date(timeIntervalSince1970: value / 1000)
        } else {
            date = .now
        }

        let body = plainText(from: payload) ?? snippet

        var message = Message(
            sender: contact(from: headers["from"] ?? ""),
            recipients: [contact(from: headers["to"] ?? "")],
            subject: headers["subject"] ?? "(No Subject)",
            body: body.isEmpty ? snippet : body,
            date: date,
            isRead: !labels.contains("UNREAD"),
            isFlagged: labels.contains("STARRED"),
            mailbox: mailbox(for: labels)
        )
        message.remoteID = json["id"] as? String
        message.threadID = json["threadId"] as? String
        message.messageIDHeader = headers["message-id"]
        message.hasAttachment = hasAttachment(in: payload)
        message.htmlBody = firstPart(in: payload, mimeType: "text/html")

        message.tags = MessageClassifier.tags(for: message, headers: headers, labels: labels)
        return message
    }

    /// Which folder a message belongs to, from Gmail's own labels.
    ///
    /// This was hardcoded to `.inbox`, which was fine while only the inbox was
    /// ever fetched. Importing Sent as well makes it wrong: every sent message
    /// would have landed in the inbox list.
    ///
    /// Order matters. A message can carry several of these at once -- a sent
    /// message that was later trashed has both -- so the most specific state
    /// wins, and INBOX is the fallback rather than the first test.
    static func mailbox(for labels: Set<String>) -> Mailbox {
        if labels.contains("TRASH") { return .trash }
        if labels.contains("DRAFT") { return .drafts }
        if labels.contains("SENT") { return .sent }
        if labels.contains("INBOX") { return .inbox }
        // Not in the inbox and not anywhere special: archived.
        return .archive
    }

    /// A part with a filename is an attachment. Inline images referenced by a
    /// HTML body have one too, so those are excluded by content-disposition
    /// where Gmail provides it.
    static func hasAttachment(in payload: [String: Any]) -> Bool {
        if let filename = payload["filename"] as? String, !filename.isEmpty {
            let headers = (payload["headers"] as? [[String: Any]] ?? [])
            let disposition = headers.first {
                ($0["name"] as? String)?.lowercased() == "content-disposition"
            }?["value"] as? String ?? ""
            if !disposition.lowercased().contains("inline") { return true }
        }
        return (payload["parts"] as? [[String: Any]] ?? []).contains { hasAttachment(in: $0) }
    }

    /// "Abel Amare <abel@example.com>" -> Contact.
    static func contact(from header: String) -> Contact {
        let trimmed = header.trimmingCharacters(in: .whitespaces)

        guard let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close else {
            // Bare address, no display name.
            return Contact(name: trimmed.isEmpty ? "Unknown" : trimmed, address: trimmed)
        }

        let address = String(trimmed[trimmed.index(after: open)..<close])
        var name = String(trimmed[trimmed.startIndex..<open])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        if name.isEmpty { name = address }
        return Contact(name: name, address: address)
    }

    /// The message body: a text/plain part if the tree has one anywhere,
    /// otherwise stripped HTML.
    ///
    /// The two searches must be separate passes. A single depth-first walk that
    /// falls back to HTML inline hits the text/html child of a
    /// multipart/alternative *before* reaching its text/plain sibling -- and
    /// since plain+HTML siblings are how most real mail is built, that quietly
    /// degrades nearly every body to stripped markup.
    static func plainText(from payload: [String: Any]) -> String? {
        if let plain = firstPart(in: payload, mimeType: "text/plain") {
            // Some senders declare a part as text/plain and fill it with a
            // stylesheet. Trusting the label there is how an email opens as a
            // wall of -webkit-text-size-adjust.
            return plain.looksLikeMarkup ? strippingHTML(plain) : plain.removingStrayMarkup()
        }
        if let html = firstPart(in: payload, mimeType: "text/html") {
            return strippingHTML(html)
        }
        return nil
    }

    static func firstPart(in payload: [String: Any], mimeType: String) -> String? {
        if payload["mimeType"] as? String == mimeType,
           let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String {
            return decode(data)
        }

        for part in payload["parts"] as? [[String: Any]] ?? [] {
            if let found = firstPart(in: part, mimeType: mimeType) { return found }
        }
        return nil
    }

    /// Gmail uses base64url, which Foundation's decoder does not accept as-is.
    static func decode(_ base64URL: String) -> String? {
        var padded = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }

        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func strippingHTML(_ html: String) -> String {
        html
            // Style and script blocks first, contents and all. Removing only
            // the tags leaves the CSS behind as body text, which is where
            // "text-decoration: none" was coming from in previews.
            .replacingOccurrences(
                of: "<style[^>]*>[\\s\\S]*?</style>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<script[^>]*>[\\s\\S]*?</script>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<head[^>]*>[\\s\\S]*?</head>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression
            )
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&zwnj;", with: "")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(\\s*\\n\\s*){3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .removingStrayMarkup()
    }

    /// Cleans a body down to something worth showing as a one-line preview.
    ///
    /// Senders put `[image: Some Alt Text]` in the plain-text alternative
    /// wherever the HTML has a picture, so a message that opens with a logo
    /// previews as "[image: Google]" and tells the reader nothing. Same for
    /// the invisible preheader padding bulk senders use to control what shows
    /// in a list.
    static func previewText(from body: String) -> String {
        body
            .replacingOccurrences(
                of: "\\[(image|cid|Image|IMAGE)\\s*:[^\\]]*\\]", with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\[image\\]", with: " ", options: [.regularExpression, .caseInsensitive])
            // Zero-width and non-breaking padding, used by bulk senders to
            // push real text out of the preview.
            .replacingOccurrences(of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00A0}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
