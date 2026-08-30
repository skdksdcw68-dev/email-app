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

    /// Recent inbox mail, newest first.
    static func fetchInbox(accessToken: String, limit: Int = 25) async throws -> [Message] {
        let ids = try await messageIDs(accessToken: accessToken, limit: limit)

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
        return ids.compactMap { byID[$0] }
    }

    private static func messageIDs(accessToken: String, limit: Int) async throws -> [String] {
        var components = URLComponents(string: "\(base)/messages")!
        components.queryItems = [
            .init(name: "maxResults", value: String(limit)),
            .init(name: "labelIds", value: "INBOX"),
        ]

        let json = try await get(components.url!, accessToken: accessToken)
        guard let messages = json["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { $0["id"] as? String }
    }

    private static func fetchMessage(id: String, accessToken: String) async throws -> Message {
        let url = URL(string: "\(base)/messages/\(id)?format=full")!
        let json = try await get(url, accessToken: accessToken)
        guard let message = parse(json) else { throw ServiceError.malformed }
        return message
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
            mailbox: .inbox
        )

        message.tags = MessageClassifier.tags(for: message, headers: headers, labels: labels)
        return message
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

    /// Walks the MIME tree for the first text/plain part, falling back to
    /// stripped HTML.
    static func plainText(from payload: [String: Any]) -> String? {
        if let mime = payload["mimeType"] as? String,
           mime == "text/plain",
           let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String {
            return decode(data)
        }

        for part in payload["parts"] as? [[String: Any]] ?? [] {
            if let text = plainText(from: part) { return text }
        }

        if let mime = payload["mimeType"] as? String,
           mime == "text/html",
           let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String,
           let html = decode(data) {
            return strippingHTML(html)
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
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(\\s*\\n\\s*){3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
