import Foundation

/// The store's half of a non-Gmail mailbox.
///
/// `MailStore` names `GmailService` directly in about two dozen places, which
/// is exactly what `MailBackend` exists to end -- but converting all of them
/// at once is a rewrite of the store, and a rewrite of the store is not a
/// thing to do in the same change that adds a new provider. So this adds the
/// IMAP path beside the Gmail one, through the protocol, and the two meet at
/// the three places that actually fetch: connecting, importing and refreshing.
///
/// Everything else -- classification, search, drafts, the AI, the archive --
/// already works on `Message` and never asked where it came from.
extension MailStore {

    /// The backend for whatever is active, kept alive between calls.
    ///
    /// 🔴 Cached, and it has to be. An IMAP backend owns a socket: building a
    /// fresh one per call would mean a TCP handshake, a TLS handshake and a
    /// LOGIN for every page of an import. That is about a second each, times
    /// however many chunks -- the difference between an import that works and
    /// one nobody waits for.
    var backend: (any MailBackend)? {
        guard let account else { return nil }

        if let cached = cachedBackend, cached.account.id == account.id {
            return cached
        }

        let fresh: (any MailBackend)?
        switch account.provider {
        case .gmail:     fresh = GmailBackend(account: account)
        case .imap:      fresh = try? IMAPBackend(account: account)
        case .microsoft: fresh = nil
        }
        cachedBackend = fresh
        return fresh
    }

    /// The import window as a query the backend can answer.
    ///
    /// The string form (`newer_than:3m`) is Gmail's and means nothing to an
    /// IMAP server, which is the whole reason `MailQuery` exists.
    var importWindow: MailQuery {
        guard let months = account?.importWindow.months else { return .everything }
        return .newerThan(months: months)
    }

    // MARK: - Connecting

    /// Takes on a mailbox that signed in somewhere other than Google.
    ///
    /// The tail of `connect()` without the Google half: the OAuth dance, the
    /// refresh token and the push registration all belong to a provider that
    /// can do them. IMAP can do none of the three -- there is no grant, the
    /// secret is a password already in the Keychain, and nothing can wake the
    /// phone.
    ///
    /// Called only once a server has actually accepted the credentials. A
    /// mailbox in the registry is one the app claims works.
    func adopt(_ connected: MailAccount) async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        // 🔴 Put the old mailbox down first.
        //
        // Without this the new account is active while `messages` still holds
        // the previous mailbox's mail, so the inbox shows one person's email
        // under another's address. It also bumps the epoch, which is what
        // stops a fetch already in flight for the old mailbox writing its
        // results into this one.
        //
        // `leaveCurrentMailbox` says in its own comment that it is "shared
        // with connect". It was not shared with anything -- only `activate`
        // called it.
        // Ordered after it, because `leaveCurrentMailbox` clears both.
        leaveCurrentMailbox()
        connectionError = nil
        importProgress = .connecting

        account = connected
        cachedBackend = nil
        registry.upsert(connected)
        registry.setActive(connected.id)

        // Before anything is written, or the first import lands in whichever
        // suite was last active and the chats and facts go to another mailbox.
        announceActiveMailbox()
    }

    // MARK: - Fetching

    /// Every id in the import window, for a backend that is not Gmail.
    ///
    /// The denominator the progress screen counts against. Ids first and
    /// bodies second is what makes "1,540 of 1,580" honest rather than a bar
    /// that guesses -- and it matters more here than on Gmail, because an
    /// IMAP server on cheap hosting is slow enough that people watch it.
    func imapRefs() async -> [String]? {
        guard let backend else { return nil }
        return try? await backend
            .allRefs(matching: importWindow, ceiling: 5_000)
            .map(\.id)
    }

    /// Bodies for one chunk of the ledger.
    func imapMessages(ids: [String]) async -> [Message] {
        guard let backend else { return [] }
        let refs = ids.map { MessageRef(id: $0) }
        return (try? await backend.messages(refs: refs)) ?? []
    }

    /// Pull-to-refresh, for an IMAP mailbox.
    ///
    /// A plain page of the inbox rather than an incremental sync. IMAP can do
    /// better -- `changes(since:)` is implemented and works off UIDNEXT -- but
    /// the store's refresh path is built around Gmail's paging and this is the
    /// honest small version until that is converted.
    func refreshIMAP() async {
        guard let backend, !isRefreshing, !importProgress.isRunning else { return }
        isRefreshing = true
        connectionError = nil
        defer { isRefreshing = false }

        let stamp = epoch
        do {
            let page = try await backend.page(
                PageRequest(query: .folder(.inbox), limit: Self.pageSize)
            )
            guard isCurrent(stamp) else { return }

            merge(page.messages)
            let snapshot = messages
            Task { [id = account?.id] in
                guard let id else { return }
                await MessageArchive.save(snapshot, mailbox: id)
            }
            Task { await enhanceWithAI() }
        } catch {
            connectionError = error.localizedDescription
        }
    }
}
