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
    /// `label` is nil to search the whole account rather than one folder,
    /// which is what a search box has to do: the message somebody is looking
    /// for is as likely to be in Sent or Archive as in the inbox.
    static func fetchInbox(
        accessToken: String,
        limit: Int = 25,
        pageToken: String? = nil,
        query: String? = nil,
        label: String? = "INBOX"
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
        label: String? = "INBOX"
    ) async throws -> ([String], String?) {
        var components = URLComponents(string: "\(base)/messages")!
        var query: [URLQueryItem] = [
            .init(name: "maxResults", value: String(limit)),
        ]
        if let label { query.append(.init(name: "labelIds", value: label)) }
        if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
        if let searchQuery { query.append(.init(name: "q", value: searchQuery)) }
        components.queryItems = query

        let json = try await get(components.url!, accessToken: accessToken)
        let next = json["nextPageToken"] as? String
        guard let messages = json["messages"] as? [[String: Any]] else { return ([], next) }
        return (messages.compactMap { $0["id"] as? String }, next)
    }

    /// Every message id matching a query, across as many pages as it takes.
    ///
    /// Ids only, so this is cheap: one request per 500 messages, and no body
    /// is fetched. That is what makes an honest denominator affordable --
    /// "1,540 of 1,580" instead of a bar that guesses, and a list the import
    /// can be resumed against.
    ///
    /// Deliberately unlabelled, so it means all mail rather than the inbox.
    /// A mailbox where things get archived, or where a filter files mail past
    /// the inbox, is not searchable if only the inbox was ever imported --
    /// and archived mail is exactly where "when did I register" lives.
    /// Gmail excludes spam and trash from an unlabelled list by default.
    static func allMessageIDs(
        matching query: String,
        accessToken: String,
        ceiling: Int = 10_000
    ) async throws -> [String] {
        var ids: [String] = []
        var token: String?

        repeat {
            let (page, next) = try await messageIDs(
                accessToken: accessToken,
                limit: idPageSize,
                pageToken: token,
                query: query,
                label: nil
            )
            ids += page
            token = next
        } while token != nil && ids.count < ceiling

        return ids
    }

    /// Gmail's maximum for a list request. Ids are small, so there is no
    /// reason to ask for fewer.
    static let idPageSize = 500

    // MARK: - Watching

    /// Asks Gmail to publish a notice to a Pub/Sub topic whenever this
    /// mailbox changes.
    ///
    /// What Gmail publishes is only the address and a history id. No sender,
    /// no subject, no body: the notice says "go and look", and the looking
    /// happens on the phone with the phone's own credentials. That is what
    /// keeps mail content off every server in the chain.
    ///
    /// Expires after seven days. Calling again renews rather than duplicating,
    /// so this runs on every launch.
    @discardableResult
    static func watch(topic: String, accessToken: String) async throws -> String? {
        let json = try await post(
            URL(string: "\(base)/watch")!,
            body: [
                "topicName": topic,
                "labelIds": ["INBOX"],
                "labelFilterBehavior": "include",
            ],
            accessToken: accessToken
        )
        return json["historyId"] as? String
    }

    /// Stops it. Called when the mailbox is disconnected, so Google is not
    /// left publishing about an account this app no longer watches.
    static func stopWatching(accessToken: String) async throws {
        _ = try? await post(URL(string: "\(base)/stop")!, body: [:], accessToken: accessToken)
    }

    // MARK: - Catching up

    /// What changed since a point in time, as Gmail records it.
    struct Changes {
        var added: [String] = []
        var removed: [String] = []
        /// Where to resume from next time.
        var historyId: String?
        /// Gmail no longer holds history that far back, so the only honest
        /// answer is a full refresh. It keeps roughly a week.
        var isExpired = false
    }

    /// Gmail's current position, to resume from later.
    static func currentHistoryID(accessToken: String) async throws -> String? {
        let json = try await get(URL(string: "\(base)/profile")!, accessToken: accessToken)
        return json["historyId"] as? String
    }

    /// Everything that happened since `startHistoryId`.
    ///
    /// This is what makes new mail appear immediately instead of on the next
    /// pull to refresh. Asking "is there anything new" costs one request and
    /// usually answers "no"; the old way listed the inbox and fetched
    /// twenty-five messages to find that out.
    static func changes(since startHistoryId: String, accessToken: String) async throws -> Changes {
        var components = URLComponents(string: "\(base)/history")!
        components.queryItems = [
            .init(name: "startHistoryId", value: startHistoryId),
            .init(name: "historyTypes", value: "messageAdded"),
            .init(name: "historyTypes", value: "messageDeleted"),
            .init(name: "maxResults", value: "100"),
        ]

        let json: [String: Any]
        do {
            json = try await get(components.url!, accessToken: accessToken)
        } catch ServiceError.http(let code, _) where code == 404 {
            // The cursor is older than Gmail's window. Not an error, just a
            // instruction to start over.
            return Changes(isExpired: true)
        }

        var result = Changes(historyId: json["historyId"] as? String)
        for entry in json["history"] as? [[String: Any]] ?? [] {
            for added in entry["messagesAdded"] as? [[String: Any]] ?? [] {
                if let message = added["message"] as? [String: Any],
                   let id = message["id"] as? String {
                    result.added.append(id)
                }
            }
            for removed in entry["messagesDeleted"] as? [[String: Any]] ?? [] {
                if let message = removed["message"] as? [String: Any],
                   let id = message["id"] as? String {
                    result.removed.append(id)
                }
            }
        }
        // The same message can be added and then deleted inside one window.
        result.added = Array(Set(result.added).subtracting(result.removed))
        return result
    }

    /// Full messages for ids that came out of a history response.
    static func messages(ids: [String], accessToken: String) async throws -> [Message] {
        guard !ids.isEmpty else { return [] }

        var byID: [String: Message] = [:]
        try await withThrowingTaskGroup(of: (String, Message?).self) { group in
            for id in ids {
                group.addTask { (id, try? await fetchMessage(id: id, accessToken: accessToken)) }
            }
            for try await (id, message) in group { byID[id] = message }
        }
        return ids.compactMap { byID[$0] }
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
                ? MailText.strippingHTML(raw)
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
    /// The two ids a draft has. Keeping them apart is the whole point: the
    /// draft endpoints want `draft`, everything else in the app wants
    /// `message`, and using one where the other belongs fails quietly.
    struct DraftHandle {
        let draft: String
        let message: String
        let thread: String?
    }

    @discardableResult
    static func createDraft(
        accessToken: String,
        envelope: MIMEBuilder.Envelope,
        threadID: String? = nil
    ) async throws -> DraftHandle {
        var message: [String: Any] = ["raw": MIMEBuilder.raw(envelope)]
        if let threadID { message["threadId"] = threadID }

        let json = try await post(
            URL(string: "\(base)/drafts")!,
            body: ["message": message],
            accessToken: accessToken
        )
        guard let id = json["id"] as? String else { throw ServiceError.malformed }
        let created = json["message"] as? [String: Any]
        return DraftHandle(
            draft: id,
            message: created?["id"] as? String ?? id,
            thread: created?["threadId"] as? String ?? threadID
        )
    }

    /// Finds the draft id for a message that carries the DRAFT label.
    ///
    /// Mail arrives here through `messages.list`, which knows nothing about
    /// drafts beyond the label, so a draft synced from Gmail has a message id
    /// and nothing else. This is the one call that pairs them up. Cheap: the
    /// listing is ids only, and there are rarely many drafts.
    static func draftID(accessToken: String, forMessage messageID: String) async throws -> String? {
        var components = URLComponents(string: "\(base)/drafts")!
        components.queryItems = [URLQueryItem(name: "maxResults", value: "200")]

        let json = try await get(components.url!, accessToken: accessToken)
        let drafts = json["drafts"] as? [[String: Any]] ?? []
        for draft in drafts {
            let message = draft["message"] as? [String: Any]
            if message?["id"] as? String == messageID { return draft["id"] as? String }
        }
        return nil
    }

    /// Replaces a draft in place, keeping its id.
    ///
    /// Reopening a draft and saving it again must not leave the half-written
    /// copy behind. Gmail has no notion of "the draft I edited" -- there is
    /// only the one it holds -- so an edit is a replacement of that exact id.
    static func updateDraft(
        accessToken: String,
        id: String,
        envelope: MIMEBuilder.Envelope,
        threadID: String? = nil
    ) async throws {
        var message: [String: Any] = ["raw": MIMEBuilder.raw(envelope)]
        if let threadID { message["threadId"] = threadID }

        var request = URLRequest(url: URL(string: "\(base)/drafts/\(id)")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": message])
        try await run(request)
    }

    /// Throws a draft away, on Gmail as well as here.
    ///
    /// Allowed by `gmail.compose`, which covers drafts. It is the only thing
    /// in Maily that deletes anything on Gmail, and it is deliberately
    /// limited to drafts -- deleting mail needs `gmail.modify`, which this
    /// app does not ask for.
    static func deleteDraft(accessToken: String, id: String) async throws {
        var request = URLRequest(url: URL(string: "\(base)/drafts/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try await run(request)
    }

    /// For the calls that answer with nothing worth reading.
    private static func run(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.http(http.statusCode, String(text.prefix(300)))
        }
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
        if let id = message.remoteID {
            message.attachments = attachments(in: payload, messageID: id)
        }
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

    /// Every real attachment in a message, without their contents.
    ///
    /// Gmail hands over a filename, a size and an `attachmentId` here; the
    /// bytes are a second request, made only when somebody opens one. Listing
    /// a mailbox must not cost what downloading it costs.
    static func attachments(in payload: [String: Any], messageID: String) -> [Attachment] {
        var found: [Attachment] = []

        func walk(_ part: [String: Any]) {
            let filename = part["filename"] as? String ?? ""
            let body = part["body"] as? [String: Any] ?? [:]

            if !filename.isEmpty, let attachmentID = body["attachmentId"] as? String {
                let headers = part["headers"] as? [[String: Any]] ?? []
                let disposition = headers.first {
                    ($0["name"] as? String)?.lowercased() == "content-disposition"
                }?["value"] as? String ?? ""

                // An image the HTML body draws inline is not something anybody
                // wants offered as a file to open.
                if !disposition.lowercased().contains("inline") {
                    found.append(
                        Attachment(
                            id: attachmentID,
                            messageRemoteID: messageID,
                            filename: filename,
                            mimeType: (part["mimeType"] as? String) ?? "application/octet-stream",
                            size: (body["size"] as? Int) ?? 0
                        )
                    )
                }
            }

            for child in part["parts"] as? [[String: Any]] ?? [] { walk(child) }
        }

        walk(payload)
        return found
    }

    /// The bytes of one attachment. Only ever called because somebody tapped
    /// it, which is what keeps a mailbox cheap to hold.
    static func attachmentData(
        messageID: String, attachmentID: String, accessToken: String
    ) async throws -> Data {
        let url = URL(string: "\(base)/messages/\(messageID)/attachments/\(attachmentID)")!
        let json = try await get(url, accessToken: accessToken)
        guard let encoded = json["data"] as? String,
              let data = Data(base64Encoded: base64Standard(encoded))
        else { throw ServiceError.malformed }
        return data
    }

    /// Gmail returns base64url. Padding is stripped too, and Foundation's
    /// decoder rejects both, so put all three back.
    private static func base64Standard(_ text: String) -> String {
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return standard
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
            return plain.looksLikeMarkup ? MailText.strippingHTML(plain) : plain.removingStrayMarkup()
        }
        if let html = firstPart(in: payload, mimeType: "text/html") {
            return MailText.strippingHTML(html)
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

// strippingHTML and previewText moved to `MailText`. They are about HTML
// and about what bulk senders do to preview text, neither of which is
// Gmail's -- and `Message.preview` was reaching into a provider service to
// format a string.
}
