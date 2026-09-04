import Foundation

/// Fetching new mail for a mailbox that is not the one in front of you.
///
/// This exists because `MailStore` cannot do it. The app deliberately keeps
/// **one** store that swaps its contents — two archives resident at once is
/// how a thirty-second background wake gets the app killed for memory — so
/// there is no second store to hand a push to. And every scoped thing the
/// store touches (`SnoozeStore`, `ClassificationCache`, the read set, the
/// sync cursor) reads `MailboxScope.defaults`, which points at the *active*
/// mailbox.
///
/// So this obeys the rule written at the top of `MailboxScope`, and it is
/// not optional:
///
/// > background work for a mailbox that is not the active one never touches
/// > a scoped store.
///
/// Everything here names its mailbox explicitly. It never calls
/// `MailboxScope.activate`, never reads `MailboxScope.defaults`, and never
/// goes near `MailStore`. Getting that wrong would write one mailbox's sync
/// cursor and read state into another's suite, from a background thread,
/// while somebody is using the app.
enum BackgroundCatchUp {

    /// Catches one mailbox up and returns what arrived in its inbox.
    ///
    /// Returns the messages worth announcing. Everything else it does — the
    /// archive, the cursor, the pending list — is so that opening that
    /// mailbox later shows what arrived rather than fetching it again.
    static func run(for account: MailAccount) async -> [Message] {
        let suite = MailboxScope.defaults(for: account.id)
        let backend = GmailBackend(account: account)

        // No cursor means this mailbox has never synced. A background wake is
        // the wrong place to import three months of mail -- iOS gives about
        // thirty seconds -- so it records where the mailbox stands and lets
        // the first real open do the work.
        guard let cursor = suite.string(forKey: cursorKey) else {
            if let now = try? await backend.checkpoint() {
                suite.set(now.token, forKey: cursorKey)
            }
            return []
        }

        guard let changes = try? await backend.changes(since: SyncCheckpoint(cursor)) else {
            return []
        }

        // The cursor is older than the provider's history. A full refresh is
        // the only honest answer and it is not a background job, so the
        // cursor is reset and the next open catches up properly.
        if changes.isExpired {
            if let now = try? await backend.checkpoint() {
                suite.set(now.token, forKey: cursorKey)
            }
            return []
        }

        guard !changes.added.isEmpty else {
            if let next = changes.next { suite.set(next.token, forKey: cursorKey) }
            return []
        }

        guard let arrived = try? await backend.messages(refs: changes.added) else { return [] }

        await absorb(arrived, removing: changes.removed, for: account.id)

        // Advanced only after the mail is safely written. Being killed
        // between the two costs a re-fetch; the other order costs the mail.
        if let next = changes.next { suite.set(next.token, forKey: cursorKey) }

        return arrived.filter { $0.mailbox == .inbox }
    }

    // MARK: - Writing it down

    private static let cursorKey = "mail.historyId"
    /// What arrived while this mailbox was not in front of anybody.
    ///
    /// The archive is the durable copy; this is the short list of what is
    /// *new* since it was last looked at, so switching to that mailbox can
    /// say so rather than quietly having more mail than before.
    static let pendingFile = "pending.json"

    private static func absorb(
        _ arrived: [Message],
        removing removed: [MessageRef],
        for mailbox: MailboxID
    ) async {
        var held = await MessageArchive.load(mailbox: mailbox)

        let gone = Set(removed.map(\.id))
        if !gone.isEmpty {
            held.removeAll { gone.contains($0.remoteID ?? "") }
        }

        var known = Set(held.compactMap(\.remoteID))
        var landed: [Message] = []
        for message in arrived {
            guard let remoteID = message.remoteID, known.insert(remoteID).inserted else { continue }
            var copy = message
            copy.accountID = mailbox
            held.append(copy)
            landed.append(copy)
        }

        guard !landed.isEmpty || !gone.isEmpty else { return }
        await MessageArchive.save(held, mailbox: mailbox)
        appendPending(landed, for: mailbox)
    }

    /// Adds to the pending list without reading the whole archive back.
    private static func appendPending(_ messages: [Message], for mailbox: MailboxID) {
        guard !messages.isEmpty else { return }
        let url = MailboxPaths.file(pendingFile, for: mailbox)

        var pending: [String] = []
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            pending = stored
        }
        pending.append(contentsOf: messages.compactMap(\.remoteID))

        // Capped. This is a "what did I miss" marker, not a log, and a
        // mailbox nobody opens for a month should not grow one.
        if pending.count > 500 { pending.removeFirst(pending.count - 500) }

        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// What a mailbox picked up while it was not being looked at, and clears
    /// it. Called when that mailbox becomes the active one.
    @discardableResult
    static func drainPending(for mailbox: MailboxID) -> [String] {
        let url = MailboxPaths.file(pendingFile, for: mailbox)
        guard let data = try? Data(contentsOf: url),
              let pending = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }

        try? FileManager.default.removeItem(at: url)
        return pending
    }
}
