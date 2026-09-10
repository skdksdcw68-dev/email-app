import UserNotifications

/// Rewrites the lock screen before anybody reads it.
///
/// The push arrives saying "New mail" and the mailbox address, because that
/// is all the server is allowed to know. iOS hands it to this extension
/// first -- the payload carries `mutable-content: 1` -- and gives it about
/// thirty seconds to make it better. It spends them fetching the newest
/// message with the mailbox's own credentials and putting the sender and the
/// subject where they belong.
///
/// The important property: this runs whether or not the app is running, and
/// whether or not somebody has swiped it away. That is the whole reason the
/// old design failed. It woke the app with a silent push to write its own
/// notification, which is a lovely idea that Apple does not guarantee to
/// deliver, and never delivers at all to an app that has been force-quit.
///
/// ## What it does not do
///
/// It does not talk to any server of Maily's, and it does not summarise.
/// The AI summary needs the classifier, and the classifier's cache lives in
/// per-mailbox `UserDefaults` suites that an extension cannot see -- sharing
/// those means an App Group and a migration of every install's stored state.
/// Until then, summarising here would pay the model twice for every email:
/// once in the extension and once again when the app catches up. The snippet
/// Gmail returns for free in the same request fills the line instead.
final class NotificationService: UNNotificationServiceExtension {

    private var handler: ((UNNotificationContent) -> Void)?
    private var draft: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        handler = contentHandler
        let draft = (request.content.mutableCopy() as? UNMutableNotificationContent)
        self.draft = draft

        guard let draft,
              let address = request.content.userInfo["address"] as? String,
              let record = PushCredentials.read(address)
        else {
            // No record for this mailbox: connected by an older build, or an
            // IMAP account, or the phone has not been unlocked since it
            // booted. The server's own wording stands, which is the whole
            // reason it is written to stand on its own.
            contentHandler(request.content)
            return
        }

        work = Task {
            if let mail = await Gmail.newest(refreshToken: record.refreshToken, clientID: record.clientID) {
                draft.title = mail.sender
                draft.body = mail.subject
                // The mailbox wins the subtitle when there is a choice to
                // make -- which account this landed in changes what somebody
                // does about it more than a preview line does. This mirrors
                // `PushDelegate.announce`, so a notification written here and
                // one written by the app look the same.
                if record.mailboxName.isEmpty {
                    // Trimmed, because a subtitle is one line and Gmail's
                    // snippet is a couple of hundred characters. Cut at a
                    // word so it reads as a sentence running on rather than
                    // as a string sliced mid-syllable.
                    if !mail.snippet.isEmpty { draft.subtitle = mail.snippet.firstLine(90) }
                } else {
                    draft.subtitle = record.mailboxName
                }
                // So tapping it opens the message rather than the inbox. The
                // app already reads `messageID`; this is Gmail's id, which is
                // what `Message.remoteID` holds.
                var info = draft.userInfo
                info["remoteID"] = mail.id
                draft.userInfo = info
            }
            contentHandler(draft)
        }
    }

    /// Thirty seconds are up. Whatever has been filled in by now is what gets
    /// shown -- and if nothing has, the server's wording is still there,
    /// because `draft` started as a copy of it rather than as an empty one.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        if let draft { handler?(draft) }
    }
}

// MARK: - Gmail, by hand

/// Two plain requests. No SDK: an extension is given a fraction of an app's
/// memory, and GoogleSignIn is a UI framework that has no business here.
private enum Gmail {

    struct Arrival {
        let id: String
        let sender: String
        let subject: String
        let snippet: String
    }

    static func newest(refreshToken: String, clientID: String) async -> Arrival? {
        guard let token = await accessToken(refreshToken: refreshToken, clientID: clientID) else {
            return nil
        }

        // The push carries a history id, and turning one into "what arrived"
        // needs the *previous* history id, which only the app has. The newest
        // thing in the inbox is the same message in every case that matters,
        // and when it is not it is still a real email rather than a guess.
        guard let listed = await get(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=1&labelIds=INBOX",
            token: token
        ),
            let messages = listed["messages"] as? [[String: Any]],
            let id = messages.first?["id"] as? String
        else { return nil }

        // Metadata only, and only the two headers that end up on screen.
        // Asking for the body would pull an entire email into an extension
        // that is measured in megabytes, to read forty characters of it.
        guard let message = await get(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)"
                + "?format=metadata&metadataHeaders=From&metadataHeaders=Subject",
            token: token
        ) else { return nil }

        let headers = (message["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        let from = header("From", in: headers) ?? ""
        let subject = header("Subject", in: headers) ?? ""

        return Arrival(
            id: id,
            sender: displayName(from),
            subject: subject.isEmpty ? "(No subject)" : subject,
            // Gmail returns this whether or not it was asked for. It is the
            // first line or so of the message, already stripped of markup.
            snippet: (message["snippet"] as? String ?? "").decodingEntities
        )
    }

    /// The refresh grant, which is the same form POST `TokenBroker` makes.
    /// An installed app has no client secret, so there is nothing else to it.
    private static func accessToken(refreshToken: String, clientID: String) async -> String? {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            [
                "client_id=\(clientID)",
                "refresh_token=\(refreshToken)",
                "grant_type=refresh_token",
            ].joined(separator: "&").utf8
        )
        // Well inside the extension's budget, and short enough that a phone
        // on a bad connection shows the server's wording quickly rather than
        // holding the banner back for half a minute.
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return payload["access_token"] as? String
    }

    private static func get(_ string: String, token: String) async -> [String: Any]? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func header(_ name: String, in headers: [[String: Any]]) -> String? {
        let match = headers.first {
            ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }
        return match?["value"] as? String
    }

    /// `Ada Lovelace <ada@example.com>` -> `Ada Lovelace`, and a bare address
    /// stays as it is. A lock screen wants the name; the address is what the
    /// server already put there and what this is replacing.
    private static func displayName(_ from: String) -> String {
        guard let open = from.lastIndex(of: "<") else {
            return from.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = from[from.startIndex..<open]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if !name.isEmpty { return name }

        let close = from.firstIndex(of: ">") ?? from.endIndex
        let address = from[from.index(after: open)..<close]
        return String(address)
    }
}

private extension String {
    /// Gmail's snippet comes back with HTML entities still in it -- `&#39;`
    /// where an apostrophe was, most commonly, which is glaring on a lock
    /// screen. Only the handful that actually turn up; a full parser is not
    /// worth linking into an extension.
    var decodingEntities: String {
        var out = self
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"),
        ] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }

    /// At most `limit` characters, cut at the last whole word.
    func firstLine(_ limit: Int) -> String {
        let flat = replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }

        let cut = flat.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[cut.startIndex..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
