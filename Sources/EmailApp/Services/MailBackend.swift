import Foundation

/// One mailbox, at whichever provider holds it.
///
/// The point of this is narrow and worth stating: **a second provider should
/// be a file that gets added, not a codebase that gets rewritten.** Today
/// twenty-six call sites name `GmailService` directly and thread an
/// `accessToken` through by hand, and every one of them would need touching
/// for Outlook.
///
/// What is in here is what the app genuinely needs a provider for. What is
/// not in here is as deliberate: parsing Gmail's JSON, mapping its labels
/// onto folders, its base64url encoding, its habit of serving a long body as
/// a second request. Those are one provider's problems and they stay behind
/// one provider's implementation.
///
/// Nothing here is `@MainActor`. A backend is a network client; the store
/// that calls it owns the isolation, and `MailStore.epoch` decides whether a
/// result that comes back late is still wanted.
protocol MailBackend: Sendable {
    /// The mailbox this instance speaks for. A backend is bound to one
    /// account and cannot be asked about another -- which is what stops the
    /// old bug where a token from the active mailbox was used to fetch a
    /// message id that belonged to a different one.
    var account: MailAccount { get }

    /// What this provider can do, so screens can soften rather than break.
    var capabilities: BackendCapabilities { get }

    // MARK: - Reading

    /// One page, newest first, and where to continue.
    func page(_ request: PageRequest) async throws -> MessagePage

    /// Full messages for ids already known. The import works this way: ids
    /// are cheap and bodies are not, so the two are separate calls.
    func messages(refs: [MessageRef]) async throws -> [Message]

    /// Every id matching a query, across as many pages as it takes.
    ///
    /// Ids only, which is what makes an honest import denominator
    /// affordable -- "1,540 of 1,580" rather than a bar that guesses.
    ///
    /// ⚠️ Callers rely on **newest first**. `MailStore+Investigation`
    /// takes `suffix(3)` to find the oldest mail matching something, and
    /// that is only the oldest if the order is what it expects. A backend
    /// whose provider returns another order has to sort before returning.
    func allRefs(matching query: MailQuery, ceiling: Int) async throws -> [MessageRef]

    func attachmentData(_ ref: AttachmentRef) async throws -> Data

    // MARK: - Writing

    func send(_ envelope: MIMEBuilder.Envelope, inThread thread: ThreadRef?) async throws -> SentReceipt

    /// Writes a draft, or replaces one. Replacing rather than adding is the
    /// point of `replacing:` -- editing a draft and saving used to leave the
    /// half-written copy behind.
    func saveDraft(
        _ envelope: MIMEBuilder.Envelope,
        replacing existing: DraftRef?,
        inThread thread: ThreadRef?
    ) async throws -> DraftRef

    func deleteDraft(_ ref: DraftRef) async throws

    // MARK: - Keeping up

    /// Where the mailbox stands right now, for a first sync.
    func checkpoint() async throws -> SyncCheckpoint

    /// What changed since. `ChangeSet.isExpired` means the checkpoint is too
    /// old to answer and a full refresh is the only honest response.
    func changes(since checkpoint: SyncCheckpoint) async throws -> ChangeSet
}

/// A backend whose provider can wake the phone on its own.
///
/// Gmail publishes to Pub/Sub, Graph posts to a webhook. IMAP does not
/// conform, and that is not an omission: IDLE means holding a socket open,
/// which iOS will not let a backgrounded app do. Freshness there is periodic
/// and best-effort, and the app should say so rather than implying otherwise.
protocol PushCapableBackend: MailBackend {
    func startPush(to destination: PushDestination) async throws -> PushRegistration
    func stopPush(_ registration: PushRegistration?) async throws
}

extension MailBackend {
    /// The query this backend will actually understand.
    ///
    /// One place, rather than a check at every call site. A provider that
    /// cannot read another's search syntax gets plain words instead of an
    /// error -- a worse search, and a search rather than a failure.
    func understandable(_ query: MailQuery) -> MailQuery {
        guard query.usesProviderSyntax, !capabilities.acceptsProviderQuerySyntax else {
            return query
        }
        return query.withoutProviderSyntax
    }
}
