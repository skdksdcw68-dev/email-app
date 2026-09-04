import Foundation

/// A mailbox at any provider that speaks IMAP, which is very nearly all of
/// them.
///
/// The second implementation of `MailBackend`, and the one the protocol was
/// actually written for -- Gmail's adapter could be shaped around Gmail
/// because Gmail was all there was. This one has to fit a protocol that was
/// designed without it, which is the only real test of whether the protocol
/// was worth writing.
///
/// Where it differs from Gmail, and why the capability flags exist:
///
/// - **No threads.** Gmail hands over a `threadId`. IMAP has no such idea, so
///   conversations are worked out from `References` -- the header chain every
///   client has maintained since long before Gmail.
/// - **No push.** Freshness is a periodic check. `canPush` is false, and
///   `PushCapableBackend` is deliberately not conformed to.
/// - **Folders are named, not labelled.** And named in the account's own
///   language, which is why `\Sent` is asked for rather than "Sent".
/// - **Sending is a different server.** Gmail sends over the same API it
///   reads with. Here, reading is IMAP and sending is SMTP on another host,
///   possibly with a different password.
struct IMAPBackend: MailBackend {

    let account: MailAccount
    private let session: IMAPSession

    init(account: MailAccount) throws {
        guard let config = account.server else {
            throw IMAPConnection.Failure.unexpected("This mailbox has no server settings.")
        }
        self.account = account
        self.session = IMAPSession(account: account, config: config)
    }

    var capabilities: BackendCapabilities {
        BackendCapabilities(
            // Every IMAP server has SEARCH. It is slower and blunter than
            // Gmail's, but it is server-side and it works on mail the phone
            // has never seen.
            canSearchServerSide: true,
            // Gmail's `from:` / `newer_than:` syntax means nothing here, so
            // the model's raw query is reduced to words instead.
            acceptsProviderQuerySyntax: false,
            hasServerDrafts: true,
            canPush: false,
            threadsNatively: false,
            maxOutboundBytes: account.server?.maxOutboundBytes ?? 25 * 1024 * 1024
        )
    }

    // MARK: - Reading

    func page(_ request: PageRequest) async throws -> MessagePage {
        let folder = try await session.folder(for: request.query)
        try await session.select(folder)

        var criteria = Self.criteria(for: request.query)
        // Paging downward through UIDs. The server returns them ascending, so
        // "the next page" is everything below the lowest one already shown.
        if let cursor = request.cursor, let below = Int(cursor), below > 1 {
            criteria += " UID 1:\(below - 1)"
        }

        let uids = try await session.search(criteria)
        let wanted = Array(uids.suffix(request.limit))
        guard !wanted.isEmpty else { return MessagePage(messages: [], cursor: nil) }

        let messages = try await session.fetch(uids: wanted, folder: folder)
        return MessagePage(
            messages: messages,
            // Nothing below the lowest means there is no next page.
            cursor: wanted.min().flatMap { $0 > 1 ? String($0) : nil }
        )
    }

    func messages(refs: [MessageRef]) async throws -> [Message] {
        let uids = refs.compactMap { Int(IMAPSession.uidPart(of: $0.id)) }
        guard !uids.isEmpty else { return [] }

        // Every ref in one call is expected to be from one folder, which is
        // how the import walks them.
        let folder = refs.first.map { IMAPSession.folderPart(of: $0.id) } ?? "INBOX"
        try await session.select(folder)
        return try await session.fetch(uids: uids, folder: folder)
    }

    func allRefs(matching query: MailQuery, ceiling: Int) async throws -> [MessageRef] {
        let folder = try await session.folder(for: query)
        try await session.select(folder)

        let uids = try await session.search(Self.criteria(for: query))
        // ⚠️ Newest first. `MailStore+Investigation` takes `suffix(3)` to find
        // the oldest matching mail, and that is only the oldest if this order
        // is what it expects. The server returns ascending.
        return uids
            .reversed()
            .prefix(ceiling)
            .map { MessageRef(id: IMAPSession.reference(folder: folder, uid: $0)) }
    }

    func attachmentData(_ ref: AttachmentRef) async throws -> Data {
        let folder = IMAPSession.folderPart(of: ref.messageID)
        guard let uid = Int(IMAPSession.uidPart(of: ref.messageID)) else { return Data() }

        try await session.select(folder)
        return try await session.part(uid: uid, section: ref.attachmentID)
    }

    // MARK: - Writing

    func send(_ envelope: MIMEBuilder.Envelope, inThread thread: ThreadRef?) async throws -> SentReceipt {
        let receipt = try await session.send(envelope)

        // Nothing files a sent message for you here. Gmail's API puts a copy
        // in Sent as a side effect of sending; SMTP delivers and forgets, so
        // without this the message is gone from the app the moment it leaves.
        if let sent = try? await session.wellKnown(.sent) {
            var filed = envelope
            filed.bcc = nil
            try? await session.append(
                MIMEBuilder.raw(filed), to: sent, flags: ["\\Seen"]
            )
        }
        return receipt
    }

    func saveDraft(
        _ envelope: MIMEBuilder.Envelope,
        replacing existing: DraftRef?,
        inThread thread: ThreadRef?
    ) async throws -> DraftRef {
        let folder = try await session.wellKnown(.drafts)

        // Written before the old one is removed. The other order loses the
        // text if the append fails, and the text is the only thing here that
        // cannot be recreated.
        try await session.select(folder)
        try await session.append(MIMEBuilder.raw(envelope), to: folder, flags: ["\\Draft"])

        if let existing, let uid = Int(IMAPSession.uidPart(of: existing.primary)) {
            try? await session.delete(uid: uid, in: folder)
        }

        // IMAP does not say what UID an APPEND produced unless the server has
        // UIDPLUS, and the reply is not read for it yet. The next sync finds
        // the draft; until then it is identified by its folder alone.
        return DraftRef(provider: .imap, primary: IMAPSession.reference(folder: folder, uid: 0))
    }

    func deleteDraft(_ ref: DraftRef) async throws {
        let folder = IMAPSession.folderPart(of: ref.primary)
        guard let uid = Int(IMAPSession.uidPart(of: ref.primary)), uid > 0 else { return }
        try await session.delete(uid: uid, in: folder)
    }

    // MARK: - Keeping up

    func checkpoint() async throws -> SyncCheckpoint {
        let selection = try await session.select("INBOX")
        // UIDVALIDITY says whether the numbering still means anything, UIDNEXT
        // says where to look for new mail. Neither is useful without the other.
        return SyncCheckpoint("\(selection.uidValidity ?? 0):\(selection.uidNext ?? 0)")
    }

    func changes(since checkpoint: SyncCheckpoint) async throws -> ChangeSet {
        let parts = checkpoint.token.split(separator: ":").map(String.init)
        guard parts.count == 2, let validity = Int(parts[0]), let since = Int(parts[1]) else {
            return ChangeSet(isExpired: true)
        }

        let selection = try await session.select("INBOX")

        // The folder was renumbered. Every UID held is now meaningless or
        // points at a different message -- the IMAP spelling of Gmail's 404
        // and Graph's 410.
        guard selection.uidValidity == validity else {
            return ChangeSet(isExpired: true)
        }

        let uids = try await session.search("UID \(since):*")
        return ChangeSet(
            added: uids
                .filter { $0 >= since }
                .map { MessageRef(id: IMAPSession.reference(folder: "INBOX", uid: $0)) },
            // A deletion is only visible by comparing the whole folder, which
            // is a sync of its own. Nothing is reported rather than something
            // wrong.
            removed: [],
            next: SyncCheckpoint("\(validity):\(selection.uidNext ?? since)")
        )
    }

    // MARK: - Queries

    /// `MailQuery` in IMAP's own grammar.
    ///
    /// The folder is not in here -- IMAP searches inside whatever is selected,
    /// so the folder is chosen by `SELECT` before the search runs.
    static func criteria(for query: MailQuery) -> String {
        let parts = terms(for: query)
        return parts.isEmpty ? "ALL" : parts.joined(separator: " ")
    }

    private static func terms(for query: MailQuery) -> [String] {
        switch query {
        case .folder(.flagged):
            return ["FLAGGED"]
        case .folder:
            return []

        case .newerThan(let months):
            guard let date = Calendar.current.date(byAdding: .month, value: -months, to: .now) else {
                return []
            }
            return ["SINCE \(imapDate(date))"]

        case .freeText(let words):
            // TEXT covers headers and body, which is the closest IMAP has to
            // what somebody means by searching their mail.
            return words.isEmpty ? [] : ["TEXT \(quoted(words))"]

        case .from(let who):
            return who.isEmpty ? [] : ["FROM \(quoted(who))"]

        case .and(let parts):
            // Criteria written one after another are ANDed. No operator.
            return parts.flatMap(terms(for:))

        case .providerRaw(let raw):
            // Gmail syntax reaching here would be searched for literally.
            // `understandable(_:)` reduces it to words before this is called;
            // this is the belt to that's braces.
            return raw.isEmpty ? [] : ["TEXT \(quoted(raw))"]
        }
    }

    /// IMAP wants `1-Jan-2025`, in English, whatever the phone is set to.
    static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter.string(from: date)
    }

    static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
