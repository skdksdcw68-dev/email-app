import Foundation

/// Gmail, behind the protocol.
///
/// Deliberately thin. Everything underneath is the `GmailService` that has
/// been working for months -- the parsing, the deferred-body second request,
/// the label mapping, the two-id drafts -- and none of it moves. What this
/// adds is the two things a protocol needs and static functions cannot have:
/// an account it is bound to, and a token it sources itself.
///
/// That second part is most of the value. Twenty-six call sites used to
/// fetch a token and pass it along, which meant twenty-six places that had
/// to know which mailbox they were talking about. Getting that wrong reads
/// another account's mail with entirely plausible-looking results.
struct GmailBackend: PushCapableBackend {
    let account: MailAccount

    var capabilities: BackendCapabilities { .gmail }

    /// Sourced per call rather than held. Tokens expire in an hour and the
    /// broker already coalesces the twenty-five concurrent asks a page fetch
    /// produces.
    private var token: String {
        get async throws { try await TokenBroker.shared.accessToken(for: account) }
    }

    // MARK: - Reading

    func page(_ request: PageRequest) async throws -> MessagePage {
        let rendered = Self.render(understandable(request.query))
        let page = try await GmailService.fetchInbox(
            accessToken: try await token,
            limit: request.limit,
            pageToken: request.cursor,
            query: rendered.search,
            label: rendered.label
        )
        return MessagePage(
            messages: page.messages.map(stamped),
            cursor: page.nextPageToken
        )
    }

    func messages(refs: [MessageRef]) async throws -> [Message] {
        let fetched = try await GmailService.messages(
            ids: refs.map(\.id), accessToken: try await token
        )
        return fetched.map(stamped)
    }

    func allRefs(matching query: MailQuery, ceiling: Int) async throws -> [MessageRef] {
        let rendered = Self.render(understandable(query))
        let ids = try await GmailService.allMessageIDs(
            matching: rendered.search ?? "",
            accessToken: try await token,
            ceiling: ceiling
        )
        // Gmail lists newest first, which `allRefs` promises and
        // `MailStore+Investigation` relies on when it takes the last three to
        // find the oldest mail matching something.
        return ids.map { MessageRef(id: $0) }
    }

    func attachmentData(_ ref: AttachmentRef) async throws -> Data {
        try await GmailService.attachmentData(
            messageID: ref.messageID,
            attachmentID: ref.attachmentID,
            accessToken: try await token
        )
    }

    // MARK: - Writing

    func send(_ envelope: MIMEBuilder.Envelope, inThread thread: ThreadRef?) async throws -> SentReceipt {
        let sent = try await GmailService.send(
            accessToken: try await token, envelope: envelope, threadID: thread?.id
        )
        return SentReceipt(id: sent.id, thread: sent.threadID)
    }

    func saveDraft(
        _ envelope: MIMEBuilder.Envelope,
        replacing existing: DraftRef?,
        inThread thread: ThreadRef?
    ) async throws -> DraftRef {
        let token = try await token

        if let existing {
            try await GmailService.updateDraft(
                accessToken: token,
                id: existing.primary,
                envelope: envelope,
                threadID: existing.thread ?? thread?.id
            )
            return existing
        }

        let handle = try await GmailService.createDraft(
            accessToken: token, envelope: envelope, threadID: thread?.id
        )
        // Both ids kept apart. The draft endpoints answer to one and the rest
        // of the app wants the other, and conflating them is a 404 nobody can
        // explain.
        return DraftRef(
            provider: .gmail,
            primary: handle.draft,
            secondary: handle.message,
            thread: handle.thread
        )
    }

    func deleteDraft(_ ref: DraftRef) async throws {
        try await GmailService.deleteDraft(accessToken: try await token, id: ref.primary)
    }

    /// Finds a draft's own id for a message that arrived through a normal
    /// sync and therefore only has a message id.
    ///
    /// Gmail-only, and not on the protocol. It exists because `messages.list`
    /// does not return draft ids, so the pairing has to be recovered by
    /// listing drafts and scanning. Graph has one id and needs no equivalent.
    func draftRef(forMessage messageID: String) async throws -> DraftRef? {
        guard let id = try await GmailService.draftID(
            accessToken: try await token, forMessage: messageID
        ) else { return nil }
        return DraftRef(provider: .gmail, primary: id, secondary: messageID)
    }

    // MARK: - Keeping up

    func checkpoint() async throws -> SyncCheckpoint {
        guard let id = try await GmailService.currentHistoryID(accessToken: try await token) else {
            throw GmailService.ServiceError.malformed
        }
        return SyncCheckpoint(id)
    }

    func changes(since checkpoint: SyncCheckpoint) async throws -> ChangeSet {
        let changes = try await GmailService.changes(
            since: checkpoint.token, accessToken: try await token
        )
        return ChangeSet(
            added: changes.added.map { MessageRef(id: $0) },
            removed: changes.removed.map { MessageRef(id: $0) },
            next: changes.historyId.map(SyncCheckpoint.init),
            isExpired: changes.isExpired
        )
    }

    // MARK: - Push

    func startPush(to destination: PushDestination) async throws -> PushRegistration {
        guard case .pubSub(let topic) = destination else {
            throw GmailService.ServiceError.malformed
        }
        let historyID = try await GmailService.watch(
            topic: topic, accessToken: try await token
        )
        // Gmail has one watch per mailbox and hands back no handle, so there
        // is no id to keep. The seven day expiry and the history id are worth
        // keeping: the first tells the app when the watch goes quiet, and the
        // second is the right starting cursor for a mailbox that has only
        // just been watched.
        return PushRegistration(
            id: nil,
            expires: .now.addingTimeInterval(7 * 24 * 60 * 60),
            checkpoint: historyID.map(SyncCheckpoint.init)
        )
    }

    func stopPush(_ registration: PushRegistration?) async throws {
        try await GmailService.stopWatching(accessToken: try await token)
    }

    // MARK: - Rendering a query

    /// Marks a message with the mailbox it came from.
    ///
    /// The archive is already per-mailbox and the epoch fence already refuses
    /// late writes, so this is belt and braces -- but it is the only thing
    /// that makes a stray message *attributable* rather than merely unlikely.
    private func stamped(_ message: Message) -> Message {
        var copy = message
        copy.accountID = account.id
        return copy
    }

    /// A `MailQuery` as Gmail wants it: a label for the folder, a search
    /// string for everything else.
    ///
    /// The split matters. Gmail's `labelIds` is a real filter and its `q` is
    /// a search, and asking for the inbox through `q` returns a different and
    /// worse answer than asking through the label.
    static func render(_ query: MailQuery) -> (label: String?, search: String?) {
        var label: String?
        var terms: [String] = []

        func walk(_ part: MailQuery) {
            switch part {
            case .folder(let mailbox):
                label = Self.label(for: mailbox)
            case .newerThan(let months):
                terms.append("newer_than:\(months)m")
            case .freeText(let text):
                if !text.isEmpty { terms.append(text) }
            case .from(let address):
                terms.append("from:\(address)")
            case .providerRaw(let raw):
                if !raw.isEmpty { terms.append(raw) }
            case .and(let parts):
                parts.forEach(walk)
            }
        }
        walk(query)

        return (label, terms.isEmpty ? nil : terms.joined(separator: " "))
    }

    /// Gmail's own name for each folder.
    ///
    /// `.flagged` is a saved search rather than a folder, so it has no label
    /// and falls back to `is:starred` as a term. `.archive` is Gmail's
    /// absence of a label, which nothing can be filtered *by*.
    private static func label(for mailbox: Mailbox) -> String? {
        switch mailbox {
        case .inbox:   "INBOX"
        case .sent:    "SENT"
        case .drafts:  "DRAFT"
        case .trash:   "TRASH"
        case .flagged: "STARRED"
        case .archive: nil
        }
    }
}
