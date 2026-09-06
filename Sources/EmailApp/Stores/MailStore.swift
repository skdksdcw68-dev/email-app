import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class MailStore {
    /// `nil` until the user connects Gmail. Everything in the Mail tab keys off this.
    /// The mailbox in front of you. One at a time; `registry` has the rest.
    /// `internal(set)` on the four below, like `heldSend`: a mailbox that is
    /// not Gmail connects through `MailStore+IMAP`, which is a different file
    /// and so cannot reach a `private(set)` setter.
    internal(set) var account: MailAccount?
    private(set) var messages: [Message]
    internal(set) var isConnecting = false
    internal(set) var isRefreshing = false
    private(set) var isEnhancing = false
    /// Surfaced in the UI rather than swallowed -- a declined consent screen
    /// or an expired grant must be visible, not a silently empty inbox.
    internal(set) var connectionError: String?

    /// The provider adapter for the active mailbox, built once and kept.
    ///
    /// An IMAP backend owns a socket, so rebuilding it per call would mean a
    /// handshake and a login for every chunk of an import. Cleared whenever
    /// the active mailbox changes.
    @ObservationIgnored var cachedBackend: (any MailBackend)?

    /// Gmail's cursor for the next page. `nil` means the mailbox is exhausted.
    private(set) var nextPageToken: String?
    private(set) var isLoadingMore = false
    /// Messages currently being summarised on demand, so the reading view can
    /// show a skeleton for exactly the one being read.
    private(set) var summarizing: Set<Message.ID> = []
    /// Bumped whenever somebody's preferences change. People are derived
    /// from messages *and* preferences, and preferences live in UserDefaults,
    /// which nothing observes on its own -- so without this, marking a
    /// person as a client showed up nowhere until something else moved.
    private(set) var preferencesVersion = 0

    /// Bumped by `write`, and the only thing that makes `derived` stale.
    private(set) var mailVersion = 0

    // MARK: - Switching mailbox
    //
    // See `MailStore+Mailboxes`, which is where the reasoning lives. Stored
    // here because an extension cannot hold state.

    private(set) var isSwitching = false
    /// Which mailbox is being switched to, so the overlay can name it.
    private(set) var switchingTo: MailAccount?

    /// Which mailbox the work in flight belongs to.
    ///
    /// This store has around ten detached tasks that write back into
    /// `messages` when they return. A page fetched for mailbox A that lands
    /// after a switch would merge A's mail into B and save the mixture to B's
    /// archive, and nothing afterwards could tell them apart. Every
    /// continuation that writes checks this first.
    @ObservationIgnored private(set) var epoch = 0

    /// True when the work that started in this epoch is still the work that
    /// matters. False means a different mailbox is in front of the person now
    /// and whatever this was doing is for the last one.
    func isCurrent(_ stamp: Int) -> Bool { stamp == epoch }

    /// The overlay must not strobe. Decoding an archive is a hundred to four
    /// hundred milliseconds, so a fast switch would flash a blur and be gone
    /// before it read as anything.
    private static let minimumSwitch: TimeInterval = 0.35

    /// Puts a different mailbox in front of the person.
    ///
    /// One store that swaps its contents, rather than a store per account.
    /// The archive is thousands of messages and several megabytes decoded;
    /// two or three resident at once in an app that has to survive a thirty
    /// second background wake is how it gets killed for memory, and the
    /// symptom of that is "notifications sometimes don't work", which is
    /// close to undiagnosable from a TestFlight build.
    ///
    /// The order below is the whole design. Save what the outgoing mailbox
    /// has, fence the work it started, clear, repoint, load.
    func activate(_ next: MailAccount) async {
        guard next.id != account?.id else { return }

        isSwitching = true
        switchingTo = next
        let started = Date.now

        leaveCurrentMailbox()

        account = next
        // The old mailbox's backend may be holding an open IMAP socket to
        // somebody else's server. Dropping it here closes it, and stops the
        // next fetch reaching the mailbox that was just left.
        cachedBackend = nil
        registry.setActive(next.id)
        // Moves the suite, the in-memory caches and the five file-backed
        // stores together.
        announceActiveMailbox()

        await loadArchive()
        // What a background push brought in while this mailbox was not the
        // one being looked at. The mail is already in the archive that was
        // just loaded; this only clears the marker saying it was unseen.
        BackgroundCatchUp.drainPending(for: next.id)

        let elapsed = Date.now.timeIntervalSince(started)
        if elapsed < Self.minimumSwitch {
            try? await Task.sleep(for: .seconds(Self.minimumSwitch - elapsed))
        }
        isSwitching = false
        switchingTo = nil

        // Only the disk read is on the critical path. The network arrives
        // behind the overlay.
        Task { await restore() }
    }

    /// Puts down whatever the current mailbox was holding.
    ///
    /// Shared with `connect`, because connecting a mailbox while another is
    /// open is a switch with a consent screen in front of it.
    func leaveCurrentMailbox() {
        // A message written and accepted belongs to the mailbox it was
        // written from. Held a few more seconds and then sent from whichever
        // account happened to be current would be somebody's reply going out
        // from the wrong address.
        sendHeldNow()
        ClassificationCache.flush()

        if let going = account {
            let snapshot = messages
            Task { await MessageArchive.save(snapshot, mailbox: going.id) }
        }

        // Nothing already running may write after this point.
        epoch &+= 1

        write { $0 = [] }
        nextPageToken = nil
        searchResults = []
        searchTerms = []
        searchExplanation = nil
        searchError = nil
        importProgress = .idle
        importAudit = nil
        connectionError = nil

        // Derived state describing the mailbox being left. Not the stored
        // copies -- those belong to that mailbox and stay with it.
        readCache = nil
        repliedCache = nil
        indexCache = nil
        positionCache = nil
    }

    // MARK: - Sending
    //
    // See `MailStore+Sending`, which is where the reasoning lives. Stored
    // here because an extension cannot hold state.

    /// A message written, accepted, and not yet gone.
    internal(set) var heldSend: HeldSend?
    /// What went wrong with the last send, for the one place that can say so
    /// after the compose sheet has already closed.
    var sendFailure: String?

    /// The send itself, kept apart from its timer so it can be run early.
    @ObservationIgnored var heldWork: (() async -> Void)?
    @ObservationIgnored var heldTimer: Task<Void, Never>?

    // MARK: - Derived

    @ObservationIgnored private var indexCache: MailboxIndex?
    @ObservationIgnored private var indexKey: (mail: Int, prefs: Int, account: String?) = (-1, -1, nil)

    /// Everything the screens read off the mailbox: counts, thread sizes,
    /// the per-mailbox lists, follow-ups. Built once per change and handed
    /// back as-is until something moves.
    ///
    /// Reading `mailVersion` and `preferencesVersion` here is what ties a
    /// screen asking for a count to the mail it came from. Without it the
    /// cache would be invisible to observation and nothing would redraw.
    var derived: MailboxIndex {
        let key = (mail: mailVersion, prefs: preferencesVersion, account: account?.address)
        if let indexCache, indexKey == key { return indexCache }

        let built = MailboxIndex(messages, myAddress: account?.address)
        indexCache = built
        indexKey = key
        return built
    }

    @ObservationIgnored private var positionCache: (version: Int, map: [Message.ID: Int])?

    /// Where each message sits in `messages`, so changing one is a lookup
    /// rather than a scan.
    ///
    /// Deliberately its own cache rather than part of `derived`. Classifying
    /// a backlog is hundreds of single-message writes, and each one asks for
    /// this -- rebuilding the sorted per-mailbox lists and the follow-ups
    /// that often would cost more than the scan it replaced. This is one
    /// pass and no sort.
    private var positions: [Message.ID: Int] {
        let version = mailVersion
        if let positionCache, positionCache.version == version { return positionCache.map }

        var map: [Message.ID: Int] = [:]
        map.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() { map[message.id] = index }
        positionCache = (version, map)
        return map
    }

    /// The one door into the mailbox.
    ///
    /// Everything derived from `messages` is cached, and this is what tells
    /// the cache it is stale -- changing `messages` any other way leaves
    /// every screen showing yesterday's numbers. It also batches: a merge of
    /// twenty-five messages is one change here, so the app redraws once
    /// rather than twenty-five times.
    private func write(_ change: (inout [Message]) -> Void) {
        change(&messages)
        mailVersion &+= 1
    }

    // MARK: - Search
    //
    // Written by `MailStore+Search`, which is where the reasoning lives.
    // Stored here because an extension cannot hold state.

    /// What Gmail returned for the last search, across the whole account.
    var searchResults: [Message] = []
    /// The words worth marking in those results.
    var searchTerms: [String] = []
    /// What an AI search decided to look for, in a sentence. Nil for a plain
    /// search, which needs no explaining.
    var searchExplanation: String?
    var isSearchingRemotely = false
    var searchError: String?

    func notePreferencesChanged() {
        preferencesVersion += 1
    }

    /// How far back the import reaches, in the provider's own words.
    ///
    /// Read off the account rather than a constant, because a mailbox decides
    /// its own window: three months is right for a Gmail account that can
    /// fetch it in a couple of minutes, and wrong for a small server on a slow
    /// host. `ImportWindow` has been on `MailAccount` since the accounts work
    /// and nothing read it until now.
    ///
    /// Still a Gmail search string here. That is the next thing to go, when
    /// `MailQuery` lands and each backend renders the window its own way.
    var importQuery: String {
        switch account?.importWindow.months {
        case .some(let months): "newer_than:\(months)m"
        // `.everything`, which has no months. An unbounded query is the
        // whole mailbox, which is exactly what was asked for.
        case .none where account != nil: ""
        default: "newer_than:3m"
        }
    }

    /// Brings back anything whose snooze has run out.
    ///
    /// Nothing about the mailbox changes when a snooze expires -- the clock
    /// moved, not the mail -- so the cached index would happily keep hiding a
    /// message past its day. This is what tells it to look again, and it is
    /// called when the app comes back to the front, which is when somebody is
    /// there to notice.
    func wakeSnoozed(now: Date = .now) {
        if SnoozeStore.forgetWoken(now: now) { notePreferencesChanged() }
    }

    /// Adds messages this app did not have, leaving everything it holds
    /// alone. Search needs it: Gmail's index reaches years further back than
    /// the three month import window, and a result has to be openable.
    ///
    /// Lives here rather than beside the search code because `messages` is
    /// `private(set)`, and that is worth keeping.
    /// Drops messages Gmail says are gone. Deleted elsewhere means deleted
    /// here; leaving them would make the app the only place they still exist.
    func forget(remoteIDs: Set<String>) {
        guard !remoteIDs.isEmpty else { return }
        write { $0.removeAll { remoteIDs.contains($0.remoteID ?? "") } }
    }

    func absorb(_ found: [Message]) {
        var known = Set(messages.compactMap(\.remoteID))
        write { list in
            for message in found {
                guard let remoteID = message.remoteID, known.insert(remoteID).inserted else { continue }
                list.append(message)
            }
        }
    }

    var isConnected: Bool { account != nil }
    var hasMoreMail: Bool { nextPageToken != nil }
    /// The very first load, when there is nothing to show yet. Drives the
    /// skeleton list rather than an empty screen.
    var isLoadingFirstPage: Bool { (isConnecting || isRefreshing) && messages.isEmpty }
    /// How many pages to pull at a time. Each id costs a second request for
    /// the full message, so a bigger page is a lot more requests in flight.
    static let pageSize = 25
    /// How many bodies the import asks for at once. Gmail allows about fifty
    /// message reads a second per user; fifty in flight, plus the second
    /// request a long body needs, was right on that line and got refused.
    static let importPageSize = 25

    /// How many of the newest inbox messages ride along with every question
    /// about mail, before relevance picks the rest.
    static let newestInContext = 10

    /// What the mail committed people to: asks, promises, open questions,
    /// dates. Filled by the second tier of the classifier, owned here because
    /// it is read out of these messages and cleared with them.
    let facts: FactStore

    /// True while a background top-up is fetching what a previous import
    /// could not, so a second launch trigger does not start a second one.
    private var isToppingUp = false

    /// Where the one-time import has got to. Drives the import screen.
    internal(set) var importProgress: ImportProgress = .idle
    /// Set once the three-month import has completed, so it never runs twice.
    var hasImported: Bool {
        get { MailboxScope.defaults.bool(forKey: "mail.hasImported") }
        set { MailboxScope.defaults.set(newValue, forKey: "mail.hasImported") }
    }

    /// Every mailbox the app knows about. The store holds one of them at a
    /// time; this holds the list, and outlives every change of which.
    let registry: MailboxRegistry

    init(
        account: MailAccount? = nil,
        registry: MailboxRegistry? = nil,
        messages: [Message] = [],
        facts: FactStore? = nil
    ) {
        let registry = registry ?? MailboxRegistry()
        self.registry = registry
        self.facts = facts ?? FactStore()

        // A previously connected mailbox is remembered so a cold launch does
        // not present the connect screen to someone already signed in. Which
        // one opens is the registry's decision -- last used, or a fixed
        // favourite.
        let active: MailAccount?
        if let account {
            registry.upsert(account)
            active = account
        } else {
            active = registry.opening
        }
        self.account = active
        self.messages = messages

        // After every stored property, because both of these reach back into
        // the object being built.
        if let id = active?.id {
            registry.setActive(id)
            MailboxScope.activate(id)
        }
    }

    /// A token for the mailbox in front of you.
    ///
    /// The one place the store asks. It used to be a parameterless call into
    /// the Google SDK, which answered for whichever single account that SDK
    /// happened to be holding -- fine with one mailbox, and quietly the wrong
    /// mailbox with two.
    ///
    /// A grant that has ended is recorded on the account rather than thrown
    /// away, so the account list can offer to sign in again. The old failure
    /// was an inbox that simply stopped filling with no explanation anywhere.
    func accessToken() async throws -> String {
        guard let account else { throw AuthService.AuthError.notConnected }
        do {
            return try await TokenBroker.shared.accessToken(for: account)
        } catch let error as TokenError {
            if error.needsReauth {
                registry.update(account.id) {
                    $0.state = .needsReauth(reason: error.errorDescription ?? "Sign in again.")
                }
                self.account = registry.account(account.id)
            }
            throw error
        }
    }

    /// Tells everything scoped which mailbox it is looking at.
    ///
    /// **Called at launch, before anything reads a file.** The file-backed
    /// stores are `@State` on the App, so they are built before there is a
    /// registry to ask and each one starts on the path the single mailbox
    /// used to use. The migration has already moved those files, so without
    /// this every one of them loads nothing and reports it as an empty
    /// history -- the conversations, the searches, the facts and the
    /// Auto-Reply queue all present as gone.
    func announceActiveMailbox() {
        guard let id = account?.id else { return }
        MailboxScope.activate(id)
        NotificationCenter.default.post(
            name: .activeMailboxChanged,
            object: nil,
            userInfo: [MailboxNotice.key: id.rawValue]
        )
    }

    /// Writes the account back to the registry, which owns persistence now.
    /// A `MailAccount` is a record that gets updated, never re-minted -- the
    /// old code built a fresh one on every launch, which is why its id could
    /// never be trusted.
    private func persistAccount() {
        guard let account else { return }
        registry.upsert(account)
    }

    /// Called at launch, and at the end of every switch. Re-establishes the
    /// Google session without a consent screen and pulls fresh mail; falls
    /// back to the connect screen only if the grant is genuinely gone.
    ///
    /// 🔴 **Gmail's restore, and only Gmail's.** This ran for whatever mailbox
    /// was active, which was harmless while every mailbox was a Google one and
    /// became a serious bug the moment one was not: switching to an IMAP
    /// mailbox called this, `restoreGmail()` answered with the *Google*
    /// session, the addresses did not match, and the branch below replaced the
    /// active account with the Google one. The mailbox was in the list, it
    /// just could never be opened -- it bounced straight back to Gmail.
    ///
    /// Worse if there is no Google session at all: the guard below would mark
    /// the IMAP mailbox `needsReauth` for a grant it never had, and drop it.
    func restore() async {
        guard isConnected, !isRefreshing else { return }

        guard account?.provider == .gmail else {
            // The same tail, without the half that only Google can answer:
            // finish an interrupted import, otherwise pull what is new.
            if hasImported { await refreshIMAP() } else { await importRecentMail() }
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        guard let session = await AuthService.restoreGmail() else {
            // The grant was revoked or expired beyond recovery. Marked rather
            // than dropped: an inbox that is simply empty is the worst way to
            // report this, and the account list can show it needs signing in
            // again.
            if let id = account?.id {
                registry.update(id) { $0.state = .needsReauth(reason: "Google ended the session.") }
            }
            account = nil
            return
        }

        // Google rotates refresh tokens, so take whatever came back rather
        // than trusting what was stored months ago.
        let restoredID = MailboxID.derive(provider: .gmail, address: session.email)
        if let refresh = session.refreshToken {
            Keychain.storeQuietly(refresh, .refreshToken, for: restoredID)
        }

        // Update the record, do not build a new one. This used to construct a
        // whole fresh account on every launch, which is how the id managed to
        // change every cold start.
        if var existing = account, existing.address == MailboxID.canonical(session.email) {
            existing.displayName = session.displayName
            // 🔴 Taken on every restore, and this is what gives the picture to
            // mailboxes that were connected before the app knew to ask for it.
            // Google also rotates the URL when somebody changes their photo,
            // so the stored one goes stale rather than staying wrong forever.
            existing.photoURL = session.photoURL
            existing.state = .ok
            account = existing
        } else {
            // A different Google account came back than the one that was
            // stored -- the device switched users under us. Take what the
            // provider says; the id derives from the address, so nothing
            // else has to be told.
            account = MailAccount(
                provider: .gmail,
                address: session.email,
                displayName: session.displayName,
                photoURL: session.photoURL,
                tint: registry.nextTint,
                connectedAt: account?.connectedAt ?? .now
            )
            if let id = account?.id { MailboxScope.activate(id) }
        }
        persistAccount()
        if let id = account?.id {
            AvatarStore.shared.ensure(key: id.rawValue, url: session.photoURL)
        }

        // An import that was interrupted -- the app killed partway through --
        // leaves a partial mailbox that would otherwise never be completed,
        // because the import only ever ran from connect().
        guard hasImported else {
            await importRecentMail()
            return
        }

        let stamp = epoch
        // Through the broker like every other call. This was the one site
        // still using the raw session token straight from the SDK, which is
        // the thing a second provider cannot supply.
        guard let token = try? await accessToken() else { return }
        if let page = try? await GmailService.fetchInbox(
            accessToken: token, limit: Self.pageSize
        ) {
            // The mailbox may have been switched while this was in flight.
            // Merging now would put the old one's mail into the new one.
            guard isCurrent(stamp) else { return }
            merge(page.messages)
            self.nextPageToken = page.nextPageToken
            let snapshot = messages
            Task { [id = account?.id] in
                guard let id else { return }
                await MessageArchive.save(snapshot, mailbox: id)
            }
            Task { await enhanceWithAI() }
        }

        // Anything a previous import could not get. Detached so a mailbox
        // that is 900 messages short does not hold the app on its launch
        // screen while they come down.
        Task { await topUpIfNeeded() }
    }

    // MARK: - Connection

    /// Connects a real mailbox and pulls recent inbox mail.
    ///
    /// Runs entirely on the device -- Gmail data never passes through a server
    /// of ours. That is both less to build and a materially lower CASA risk
    /// profile, since the assessment trigger is an app able to reach restricted
    /// data "from or through a third-party server".
    /// Connects a mailbox and makes it the one in front of you.
    ///
    /// No longer refuses when something is already connected -- that guard is
    /// what made a second mailbox impossible even from code. What it refuses
    /// instead is the *same* mailbox twice, which without a check looks like
    /// it worked and changes nothing: the id derives from the address, so it
    /// lands on the record that is already there.
    /// Fetches a picture for every Google mailbox that has none yet.
    ///
    /// The active one is covered by `restore()`, which has the SDK session to
    /// hand. This is for the others: `GIDSignIn` holds exactly one session, so
    /// without this a second Gmail account keeps a coloured letter forever
    /// while the first wears a photograph -- and two accounts drawn to
    /// different rules in the same list reads as a bug.
    ///
    /// Only ever fills gaps. A mailbox that already has a URL is left alone;
    /// keeping those fresh is `restore()`'s job for the one it can, and a
    /// week's staleness on the others is not worth a call per launch.
    func refreshMailboxPhotos() async {
        for account in registry.accounts
        where account.provider == .gmail && account.photoURL == nil {
            guard let token = try? await TokenBroker.shared.accessToken(for: account),
                  let photo = await GmailService.profilePhoto(accessToken: token)
            else { continue }

            registry.update(account.id) { $0.photoURL = photo }
            if self.account?.id == account.id { self.account?.photoURL = photo }
            AvatarStore.shared.ensure(key: account.id.rawValue, url: photo)
        }
    }

    /// Refreshes the contact photos used for sender avatars.
    ///
    /// Tries each Google mailbox in turn and stops as soon as one works --
    /// `PeopleDirectory.refresh` returns immediately once it has a day-old
    /// answer, so the second mailbox costs nothing after the first succeeds.
    ///
    /// A mailbox whose grant does not include Contacts answers 403, which is
    /// read as "no photos" and nothing else: the person sees the letters and
    /// logos they saw before, and is never told about a permission they
    /// declined on purpose.
    ///
    /// `force` is for the moment the permission is granted from Settings: the
    /// day-old answer on disk was fetched under the narrower grant and has
    /// none of the faces the wider one just made reachable.
    func refreshContacts(force: Bool = false) async {
        for account in registry.accounts where account.provider == .gmail {
            guard let token = try? await TokenBroker.shared.accessToken(for: account) else {
                continue
            }
            await PeopleDirectory.shared.refresh(accessToken: token, force: force)
        }
    }

    /// Signs in to Google and adopts the mailbox.
    ///
    /// 🔴 `importNow` exists because of a bug that made a question pointless.
    ///
    /// This used to end by importing, unconditionally. In `AddMailboxFlow`
    /// that happens during the *consent* step -- two screens before anybody is
    /// asked how far back to go -- so the import ran with the default three
    /// months, finished, and marked the ledger complete. The scope screen then
    /// set the window to Everything and asked for an import that returned
    /// straight away, because the ledger said there was nothing left to do.
    /// Choosing "Everything" silently did nothing, and looked like it worked.
    ///
    /// The flow now says when to import, which is after it has asked.
    func connect(importNow: Bool = true) async {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        importProgress = .connecting
        defer { isConnecting = false }

        do {
            let session = try await AuthService.connectGmail()

            if let existing = registry.account(forAddress: session.email),
               existing.id != account?.id {
                connectionError = "\(existing.address) is already here. Switch to it from Mailboxes."
                importProgress = .idle
                return
            }
            // The same reason as in `adopt`: a second Google account added
            // while a first is open would otherwise arrive with the first
            // one's mail still in memory, and show it under the new address.
            leaveCurrentMailbox()
            // It clears this on the way out, and the screen is still showing.
            importProgress = .connecting

            let connected = MailAccount(
                provider: .gmail,
                address: session.email,
                displayName: session.displayName,
                photoURL: session.photoURL,
                tint: registry.nextTint,
                connectedAt: .now
            )
            // Started here rather than left to the first row that draws it, so
            // the face is usually already on disk by the time the flow gets
            // past the import screen.
            AvatarStore.shared.ensure(key: connected.id.rawValue, url: session.photoURL)
            // If they said yes to Contacts on the consent screen, fetch the
            // faces now rather than at the next launch -- the inbox they are
            // about to see for the first time is the one that most wants them.
            if session.grantsContacts {
                Task { await PeopleDirectory.shared.refresh(accessToken: session.accessToken) }
            }
            // The long-lived half, kept where this app can reach it. Google's
            // SDK holds exactly one session, so a second mailbox would lose
            // the first the moment it signed in -- see `TokenBroker`.
            if let refresh = session.refreshToken {
                Keychain.storeQuietly(refresh, .refreshToken, for: connected.id)
            }

            account = connected
            registry.upsert(connected)
            registry.setActive(connected.id)
            // Point the scoped stores at it before anything is written, or
            // the first import would land in whatever suite was last active
            // and the chats and facts would be written to the wrong mailbox.
            announceActiveMailbox()

            // A device row and a watch for the mailbox that just arrived.
            // APNs hands its token over about once per install, long before
            // this account existed, so nothing else would ever register it --
            // which is why every account after the first got no notifications.
            PushDelegate.push?.register(for: registry.accounts)
            Task { [accounts = registry.accounts] in
                await PushDelegate.push?.startWatchingAll(
                    topic: PushService.topic, accounts: accounts
                )
            }

            if importNow { await importRecentMail() }
        } catch {
            connectionError = error.localizedDescription
            account = nil
        }
    }

    /// Re-pulls the inbox with a refreshed token. Pull-to-refresh, for now;
    /// incremental History API sync comes with the backend.
    func refresh() async {
        // Not while the import is running. It is already fetching everything a
        // refresh would, and two writers to the mailbox at once is how the
        // counter used to disagree with itself.
        guard isConnected, !isRefreshing, !importProgress.isRunning else { return }

        if account?.provider == .imap {
            await refreshIMAP()
            return
        }
        isRefreshing = true
        connectionError = nil
        defer { isRefreshing = false }

        let stamp = epoch
        do {
            let token = try await accessToken()
            let page = try await GmailService.fetchInbox(accessToken: token, limit: Self.pageSize)
            guard isCurrent(stamp) else { return }
            merge(page.messages)
            nextPageToken = page.nextPageToken
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

    /// Pulls the window of mail, and can be picked up where it stopped.
    ///
    /// The shape that matters is the ledger. Gmail is asked for every id in
    /// the window first -- ids are cheap, 500 to a request, no bodies -- so
    /// the denominator is real before a single message is downloaded. Bodies
    /// come after, in chunks, and an id is crossed off only once the message
    /// behind it is on disk.
    ///
    /// What this replaces: a loop that broke out of the whole import on the
    /// first failed request and wrote `hasImported = true` regardless. One
    /// dropped request at page six left 300 messages of 1,580 and a flag
    /// saying the mailbox was complete, which nothing ever revisited. Now a
    /// failed chunk goes to the back of the queue, the rest carries on, and
    /// whatever is still owed is finished by `topUpIfNeeded()` on a later
    /// launch.
    func importRecentMail() async {
        guard isConnected else { return }

        guard let ledger = await openLedger() else {
            // Gmail could not even be asked what is there. Nothing is marked
            // done, so the next launch starts this again.
            importProgress = .idle
            return
        }

        guard !ledger.isComplete else {
            hasImported = true
            importProgress = .finished(count: messages.count, missing: 0)
            return
        }

        await drain(ledger, quietly: false)
    }

    /// Fetches whatever a previous run could not, with no progress screen.
    ///
    /// Called at launch. An import that lost pages to a bad connection is
    /// finished here -- a day later if that is what it takes -- rather than
    /// leaving the mailbox permanently short of the mail the assistant is
    /// then asked to search.
    func topUpIfNeeded() async {
        guard isConnected, hasImported, !isToppingUp else { return }
        isToppingUp = true
        defer { isToppingUp = false }

        // A ledger whose ids are still inside the window is the cheap path:
        // it already knows exactly what is owed.
        if let ledger = ImportLedger.load(), !ledger.isComplete, !ledger.isStale {
            await drain(ledger, quietly: true)
            return
        }

        // No ledger, or one written so long ago that the window has moved
        // past its ids. Either way the app no longer knows whether it has the
        // three months it claims to, so it asks rather than assuming.
        //
        // This used to clear the ledger and return, which is how a mailbox
        // could stay permanently short: `hasImported` was set the moment
        // anything landed, so the import never ran again, and the only thing
        // that knew mail was missing had just been thrown away. An account
        // that lost most of a first import stayed that way for good, and the
        // assistant was asked to search a mailbox with the evidence removed.
        ImportLedger.clear()
        await verifyAgainstGmail()
    }

    /// What Gmail says is in the three month window, against what is actually
    /// here -- and fetches the difference.
    ///
    /// Ids are cheap: the whole window is four requests of five hundred, and
    /// bodies are only asked for where one is genuinely missing. Run at
    /// launch, at most once a day, so a mailbox cannot drift short without
    /// anything noticing.
    func verifyAgainstGmail(force: Bool = false) async {
        guard isConnected else { return }
        // Named for Gmail because it is Gmail's: it counts against a
        // `newer_than:` query and Gmail's message ids. The IMAP path keeps its
        // own ledger and tops up from that.
        guard account?.provider != .imap else { return }
        if !force, let last = lastVerifiedAt,
           Date.now.timeIntervalSince(last) < Self.verifyInterval { return }

        let stamp = epoch
        guard let token = try? await accessToken() else { return }
        guard let ids = await Self.retrying({
            try await GmailService.allMessageIDs(
                matching: importQuery, accessToken: token
            )
        }) else { return }
        // Counting the whole window is four round trips. Comparing one
        // mailbox's ids against another's held mail would report thousands
        // missing and then fetch them all into the wrong account.
        guard isCurrent(stamp), !ids.isEmpty else { return }

        let held = Set(messages.compactMap(\.remoteID))
        let missing = ids.filter { !held.contains($0) }
        lastVerifiedAt = .now
        importAudit = ImportAudit(expected: ids.count, missing: missing.count)

        guard !missing.isEmpty else { return }

        let ledger = ImportLedger(
            pending: missing, done: ids.count - missing.count, total: ids.count
        )
        ledger.save()
        await drain(ledger, quietly: true)

        // What the top-up actually recovered, so the storage screen is not
        // still reporting the shortfall it just fixed.
        let after = Set(messages.compactMap(\.remoteID))
        importAudit = ImportAudit(
            expected: ids.count, missing: ids.filter { !after.contains($0) }.count
        )
    }

    /// Gmail's count for the window against ours, for the storage screen.
    struct ImportAudit: Equatable {
        let expected: Int
        let missing: Int
        var held: Int { expected - missing }
        var isComplete: Bool { missing == 0 }
    }

    private(set) var importAudit: ImportAudit?

    /// Once a day. The check is four requests; doing it on every launch would
    /// be four requests nobody asked for, and mail does not fall out of a
    /// mailbox that fast.
    static let verifyInterval: TimeInterval = 24 * 60 * 60

    private var lastVerifiedAt: Date? {
        get { MailboxScope.defaults.object(forKey: "mail.lastVerifiedAt") as? Date }
        set { MailboxScope.defaults.set(newValue, forKey: "mail.lastVerifiedAt") }
    }

    /// How much of the mailbox is still owed, for the settings screen.
    var importShortfall: Int {
        ImportLedger.load()?.pending.count ?? 0
    }

    /// An unfinished ledger to resume, or a fresh one counted from Gmail.
    private func openLedger() async -> ImportLedger? {
        if let saved = ImportLedger.load(), !saved.isComplete, !saved.isStale {
            return saved
        }

        importProgress = .counting

        let ids: [String]
        if account?.provider == .imap {
            guard let refs = await imapRefs() else { return nil }
            ids = refs
        } else {
            guard let token = try? await accessToken() else { return nil }
            guard let fetched = await Self.retrying({
                try await GmailService.allMessageIDs(
                    matching: importQuery, accessToken: token
                )
            }) else { return nil }
            ids = fetched
        }

        let ledger = ImportLedger(pending: ids)
        ledger.save()
        return ledger
    }

    /// Works the ledger down to nothing, or to what will not come today.
    ///
    /// The ledger in memory and the one on disk are allowed to differ, on
    /// purpose. The one here is crossed off the moment a message arrives, so
    /// the loop moves on and the counter only ever climbs. The one on disk is
    /// written only after the archive is, so being killed between the two
    /// costs a re-fetch and never a hole.
    ///
    /// The first version kept a single ledger and crossed it off at the
    /// flush. `nextChunk` reads the front of the queue, and nothing left the
    /// front until 250 had been fetched, so it handed back the same fifty ids
    /// five times over: every chunk was downloaded five times, the counter
    /// climbed to 250 and fell back to 50 each time the flush caught up, and
    /// Gmail, asked for everything five times, started refusing.
    private func drain(_ start: ImportLedger, quietly: Bool) async {
        let stamp = epoch
        // The system allows a little more time after the person leaves. Long
        // enough for the chunk in flight and the write behind it, so putting
        // the phone down does not undo the last half minute.
        let grace = UIApplication.shared.beginBackgroundTask(withName: "mail.import")
        defer { if grace != .invalid { UIApplication.shared.endBackgroundTask(grace) } }

        var ledger = start
        // A resume builds on the mail already here rather than fetching it
        // twice.
        var collected = messages
        // Landed, not yet on disk.
        var held: [Message] = []
        // Ids Gmail did not hand over. A first miss is usually a rate limit
        // and is tried again at the back of the queue; a second miss is left
        // for a later launch rather than tried all afternoon.
        var missedOnce = Set<String>()
        var refused = Set<String>()

        if !quietly {
            importProgress = .importing(done: ledger.done, total: ledger.total)
        }

        while let chunk = ledger.nextChunk(Self.importPageSize) {
            // Back round to ids already tried twice: everything left has had
            // its turn, so stop rather than spin.
            if chunk.allSatisfy(refused.contains) { break }

            let fetched: [Message]
            if account?.provider == .imap {
                fetched = await imapMessages(ids: chunk)
            } else {
                guard let token = try? await accessToken() else { break }
                fetched = await Self.retrying({
                    try await GmailService.messages(ids: chunk, accessToken: token)
                }) ?? []
            }

            // Only what actually arrived is crossed off. A message Gmail
            // refused mid-chunk used to be marked done along with the rest,
            // and was never asked for again.
            let landed = Set(fetched.compactMap(\.remoteID))
            let missing = chunk.filter { !landed.contains($0) }

            held += fetched
            ledger.complete(chunk.filter(landed.contains))

            if !missing.isEmpty {
                for id in missing where !missedOnce.insert(id).inserted {
                    refused.insert(id)
                }
                ledger.postpone(missing)
                // A miss is usually Gmail asking for a moment. Give it one.
                try? await Task.sleep(for: .seconds(1))
            }

            if !quietly {
                importProgress = .importing(done: ledger.done, total: ledger.total)
            }

            // Write, then let the disk catch up. That order is the whole
            // guarantee.
            if held.count >= Self.importFlushEvery {
                collected = Self.folding(held, into: collected)
                if let id = account?.id { await MessageArchive.save(collected, mailbox: id) }
                ledger.save()
                held = []
            }
        }

        if !quietly { importProgress = .saving }

        if !held.isEmpty {
            collected = Self.folding(held, into: collected)
        }
        if let id = account?.id { await MessageArchive.save(collected, mailbox: id) }

        // Everything arrives at once, after the progress screen has said it
        // is finishing. One layout pass instead of twenty. Folded rather than
        // assigned: mail that a catch-up or a search brought in while this
        // ran is not thrown away by it.
        guard isCurrent(stamp) else { return }
        let read = locallyRead
        let replied = locallyReplied
        write { list in
            list = Self.folding(collected, into: list)
            Self.applyLocalReadState(to: &list, read: read, replied: replied)
        }
        nextPageToken = nil

        if ledger.isComplete {
            ImportLedger.clear()
        } else {
            ledger.save()
        }

        // The screen is done with once the bulk is here; the remainder is
        // topped up quietly on a later launch. Nothing at all, though, is a
        // failed import, and saying otherwise is what caused this.
        if !collected.isEmpty { hasImported = true }

        if !quietly {
            importProgress = .finished(count: collected.count, missing: ledger.pending.count)
        }
        Task { await enhanceWithAI() }
    }

    /// Folds newly fetched messages into a growing collection, newest kept.
    private static func folding(_ fetched: [Message], into existing: [Message]) -> [Message] {
        var byRemoteID: [String: Int] = [:]
        for (index, message) in existing.enumerated() {
            if let remoteID = message.remoteID { byRemoteID[remoteID] = index }
        }

        var result = existing
        for message in fetched {
            guard let remoteID = message.remoteID else {
                result.append(message)
                continue
            }
            if let index = byRemoteID[remoteID] {
                var updated = message
                updated.tags = result[index].tags
                updated.aiSummary = result[index].aiSummary
                result[index] = updated
            } else {
                result.append(message)
                byRemoteID[remoteID] = result.count - 1
            }
        }
        return result
    }

    /// Three goes with a widening pause, then it hands back nothing.
    ///
    /// A single dropped request is the normal condition of a phone, not a
    /// reason to abandon a mailbox. Returning nil rather than throwing is
    /// deliberate: the caller's job is to carry on with the rest.
    static func retrying<T>(
        attempts: Int = 3,
        _ work: () async throws -> T
    ) async -> T? {
        for attempt in 1...attempts {
            if let value = try? await work() { return value }
            guard attempt < attempts else { break }
            try? await Task.sleep(for: .milliseconds(400 * attempt))
        }
        return nil
    }

    /// Messages held in memory before a write. Big enough that the archive is
    /// not rewritten every chunk, small enough that a kill costs little.
    static let importFlushEvery = 250

    /// Folds a freshly fetched page into what is already held, rather than
    /// replacing it.
    ///
    /// Replacing was fine when the app only ever showed one page. With an
    /// archive of three months behind it, a refresh returning the newest 25
    /// would throw the rest away -- and take every AI tag with it.
    func merge(_ fetched: [Message]) {
        var byRemoteID: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let remoteID = message.remoteID { byRemoteID[remoteID] = index }
        }

        let read = locallyRead
        let replied = locallyReplied

        // One write for the whole page. Message by message, this was
        // twenty-five redraws of every screen showing a count.
        write { list in
            for message in fetched {
                guard let remoteID = message.remoteID else {
                    list.append(message)
                    continue
                }
                if let index = byRemoteID[remoteID] {
                    // Keep what the model worked out; take everything else
                    // fresh, so read state and flags follow Gmail.
                    var updated = message
                    updated.tags = list[index].tags
                    updated.aiSummary = list[index].aiSummary
                    list[index] = updated
                } else {
                    list.append(message)
                    byRemoteID[remoteID] = list.count - 1
                }
            }

            Self.applyLocalReadState(to: &list, read: read, replied: replied)
        }
    }

    /// Restores the archive so a cold launch has mail on screen before any
    /// network call finishes.
    func loadArchive() async {
        guard messages.isEmpty else { return }
        guard let mailbox = account?.id else { return }
        let stamp = epoch
        let stored = await MessageArchive.load(mailbox: mailbox)
        // Decoding a few thousand messages takes long enough to switch
        // mailboxes underneath it, and this one writes the whole array.
        guard isCurrent(stamp), !stored.isEmpty, messages.isEmpty else { return }
        let read = locallyRead
        let replied = locallyReplied
        write { list in
            list = stored
            Self.applyLocalReadState(to: &list, read: read, replied: replied)
        }
    }

    /// Pulls the next page as the user reaches the end of the list.
    ///
    /// Gmail hands over a page at a time and will not give up a whole mailbox
    /// at once, so "show me everything" is this, called repeatedly, rather
    /// than one big request.
    func loadMore() async {
        guard isConnected, !isLoadingMore, !isRefreshing, let token = nextPageToken else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let stamp = epoch

        do {
            let accessToken = try await accessToken()
            let page = try await GmailService.fetchInbox(
                accessToken: accessToken, limit: Self.pageSize, pageToken: token
            )

            // A message arriving while the user scrolls shifts Gmail's paging
            // window, so the same id can come back on two pages. Appending it
            // twice would crash the list on duplicate ids.
            let known = Set(messages.compactMap(\.remoteID))
            let fresh = page.messages.filter { message in
                guard let remoteID = message.remoteID else { return true }
                return !known.contains(remoteID)
            }

            guard isCurrent(stamp) else { return }
            write { $0.append(contentsOf: fresh) }
            nextPageToken = page.nextPageToken
            Task { await enhanceWithAI() }
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Summarises one message on demand, when it is opened.
    ///
    /// The background pass only reaches the top of the list, and skips bulk
    /// mail to save money. But anything a person actually opens should have a
    /// summary, so opening pays for that one message -- and only once, since
    /// the result is cached like any other.
    func summarize(_ id: Message.ID) async {
        guard AppSettings.writesSummaries else { return }
        guard let message = message(id), message.aiSummary == nil else { return }
        guard !summarizing.contains(id) else { return }

        if let remoteID = message.remoteID,
           let cached = ClassificationCache.entry(for: remoteID) {
            apply(AIService.Classification(cached), to: id)
            return
        }

        summarizing.insert(id)
        defer { summarizing.remove(id) }

        let stamp = epoch
        guard let classification = try? await AIService.classify(message) else { return }
        // The summary belongs to the message it was asked about, and that
        // message belongs to a mailbox. Applying it after a switch would put
        // it on whatever now sits at that id.
        guard isCurrent(stamp) else { return }
        apply(classification, to: id)
        if let remoteID = message.remoteID {
            ClassificationCache.store(classification, for: remoteID)
        }
    }

    /// Conversations waiting on somebody, in either direction, minus the ones
    /// waved away that have not moved since.
    /// Built once per change in `MailboxIndex`. The AI tab asks for these
    /// three times in a single draw, and each ask used to rebuild every
    /// thread and then read UserDefaults once per row.
    var followUps: [FollowUp] {
        derived.followUps
    }

    /// Waves one away. It comes back if the conversation moves again.
    func dismissFollowUp(_ id: String) {
        FollowUpPreferences.dismiss(id)
        notePreferencesChanged()
    }

    func restoreFollowUp(_ id: String) {
        FollowUpPreferences.restore(id)
        notePreferencesChanged()
    }

    /// The messages worth showing the model for a given question.
    ///
    /// Retrieval happens here, on the device, against the archive we already
    /// hold -- so a question costs roughly what classifying one email costs,
    /// rather than what reading the mailbox costs. Only these few go over the
    /// wire, and only their headers and opening lines.
    /// Twelve, not twenty. Every one of these costs tokens on every question,
    /// and past the first handful the model is reading noise: the answers that
    /// needed the twentieth-best match did not exist.
    /// `following` is what Maily said last. A question is often not a whole
    /// question: "yes", "the second one", "what about her". Retrieving on the
    /// bare words of those finds nothing, and the model then answers a
    /// question nobody asked with no mail in front of it. Short replies
    /// inherit the subject of what they are replying to.
    func context(for question: String, following: String? = nil, limit: Int = 12) -> [Message] {
        let isFollowUp = question.split(separator: " ").count <= 4
        let query = isFollowUp && following != nil ? "\(question) \(following!)" : question

        let words = Set(
            query.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !Self.stopWords.contains($0) }
        )

        // What those words nearly mean. "The laptop" scored zero against an
        // email that says MacBook throughout, and the message was right there
        // on the phone. Worth less than a word actually typed, so an email
        // that says laptop still wins. On device only -- see `SemanticIndex`.
        let nearby = SemanticIndex.expand(words)

        let scored = messages.map { message -> (message: Message, keyword: Int, total: Int) in
            var keyword = 0

            if !words.isEmpty {
                let haystack = "\(message.subject) \(message.sender.name) \(message.body.prefix(400))".lowercased()
                keyword = words.filter(haystack.contains).count * 10
                keyword += nearby.filter(haystack.contains).count * 4
            }

            // Recency and priority break ties, and carry the whole thing for a
            // vague question like "what needs my attention" that matches no
            // keywords at all.
            var score = keyword
            let days = Calendar.current.dateComponents([.day], from: message.date, to: .now).day ?? 99
            score += max(0, 14 - days)
            if message.tags.contains(.urgent) { score += 12 }
            if message.tags.contains(.veryImportant) { score += 8 }
            if message.tags.contains(.needsReply) { score += 6 }
            if message.tags.contains(.noReplyNeeded) { score -= 8 }

            return (message, keyword, score)
        }

        // Nothing matched a word, and nothing in the question is about mail:
        // "what can you do", "how does this work", "write me a haiku". The
        // recency bonus alone would still hand over a dozen emails, so every
        // aside cost as much as a real question and came back captioned with
        // sources it never read. Send none.
        if !scored.contains(where: { $0.keyword > 0 }) && !mentionsMail(query) {
            return []
        }

        // A shortlist by words, then a re-rank by meaning.
        //
        // The word pass is what makes this affordable -- embedding is per
        // message work, and a mailbox is thousands of them. So the cheap
        // score picks the hundred worth thinking about and the sentence
        // model orders those. It is what catches "when am I meeting the
        // accountant" against "confirming Thursday 2pm with Grant Thornton",
        // where not one word is shared.
        let promising = scored
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .prefix(SemanticIndex.shortlist)

        let meaning = SemanticIndex.similarity(of: promising.map(\.message), to: query)

        let best = promising
            .map { candidate -> (message: Message, total: Double) in
                // Scaled to sit alongside the keyword score rather than
                // above it. A word the person actually typed is still the
                // strongest signal there is; this breaks ties and rescues
                // the message that says the same thing differently.
                let closeness = meaning[candidate.message.id] ?? 0
                return (candidate.message, Double(candidate.total) + closeness * 25)
            }
            .sorted { $0.total > $1.total }
            .prefix(limit)
            .map(\.message)

        // The newest, always, whatever they scored.
        //
        // "What was the last email I got" is a question about order, not
        // relevance, and ranking by relevance answered it with whatever
        // happened to be most urgent: the newest message was not in the
        // digest at all, so the model named the top of a list it had been
        // handed and got it wrong with complete confidence. Ten rather than
        // three, because "my last ten emails" is the same question with a
        // number in it, and the model can only show what it was handed.
        let newest = messages(in: .inbox).prefix(Self.newestInContext)

        var seen = Set<Message.ID>()
        return (Array(newest) + best)
            .filter { seen.insert($0.id).inserted }
            // Newest first, and the prompt says so. Order the model can see
            // is order it can answer about.
            .sorted { $0.date > $1.date }
    }

    /// Whether this is a question about their mail, for callers deciding
    /// whether a lookup is worth making.
    func looksLikeMailQuestion(_ question: String) -> Bool {
        mentionsMail(question)
    }

    /// Whether the question is about the mailbox at all. Deliberately broad:
    /// handing over context that is not needed wastes tokens, but withholding
    /// it from a real question gives a wrong answer, so this errs towards yes.
    private func mentionsMail(_ question: String) -> Bool {
        let q = question.lowercased()
        if Self.mailNouns.contains(where: q.contains) { return true }
        if AITag.allCases.contains(where: { q.contains($0.title.lowercased()) }) { return true }
        // A sender's name is a question about mail even with no other clue:
        // "anything from Sara?". Matched on whole words, so a name does not
        // turn up inside an unrelated one.
        let spoken = Set(q.components(separatedBy: CharacterSet.alphanumerics.inverted))
        return messages.contains { message in
            let name = message.sender.name.lowercased()
            if name.count >= 3 && q.contains(name) { return true }
            guard let first = name.split(separator: " ").first, first.count >= 3 else { return false }
            return spoken.contains(String(first))
        }
    }

    private static let mailNouns: [String] = [
        "email", "e-mail", "mail", "inbox", "message", "sender", "unread",
        "read", "reply", "replies", "replied", "respond", "answer", "waiting",
        "follow up", "follow-up", "thread", "subject", "attachment", "invoice",
        "meeting", "deadline", "urgent", "important", "newsletter", "promotion",
        "spam", "starred", "flagged", "tag", "tags", "today", "this week",
        "yesterday", "from ", "sent me", "wrote", "anything new",
        // Looking something up is a question about mail even when the word
        // "mail" never appears. "Find me my registration date on upwork" is
        // the case that went unanswered.
        "find", "search", "look for", "look up", "when did", "did i", "do i have",
        "receipt", "confirmation", "order", "booking", "ticket", "registration",
        "signed up", "sign up", "account", "password", "verify", "verification",
    ]

    private static let stopWords: Set<String> = [
        "what", "which", "there", "their", "about", "should", "would", "could",
        "have", "this", "that", "with", "from", "they", "them", "been", "were",
        "does", "email", "emails", "mail", "maily", "please", "show",
    ]

    /// How many messages share this one's conversation. 1 means it stands alone.
    /// A dictionary lookup, because this is asked once per visible row.
    /// It used to scan the whole mailbox for every row on screen, which is
    /// what made scrolling a long inbox stutter.
    func threadCount(for message: Message) -> Int {
        guard let thread = message.threadID else { return 1 }
        return derived.threadSizes[thread] ?? 1
    }

    /// Second pass over the mailbox: the model reads what the rules could only
    /// guess at, and replaces the priority it inferred.
    ///
    /// Two tiers. The first reads the opening of every message that is not
    /// bulk and settles priority, kind and whether a reply is wanted. It also
    /// says whether a closer read would find anything: an ask, a promise, a
    /// date. Only those go to the second tier, which reads the whole message
    /// and writes down what is in it as facts. Most mail never reaches it,
    /// which is what keeps the whole pass cheap.
    ///
    /// Bulk mail is skipped entirely. The rules already settled it from a
    /// List-Unsubscribe header, and it is the largest bucket -- not paying to
    /// have a model confirm that a newsletter is a newsletter is most of the
    /// cost saving. Sent mail skips the first tier instead: it is written by
    /// a person by construction, and what it promised is exactly what the
    /// second tier is for.
    ///
    /// Works through the backlog in batches rather than stopping at the first
    /// fifteen. It used to stop, so only the top of the list was ever read by
    /// the model and "what did I promise last month" had nothing to go on.
    func enhanceWithAI(limit: Int = 15) async {
        // Conversations move on whether or not the model is allowed to read
        // them, and a fact crossed off by a reply should not wait for that.
        if let account {
            facts.reconcile(with: messages, myAddress: account.address, replied: locallyReplied)
        }

        // The setting is real: off means nothing leaves the device and nothing
        // is charged. Local rules still tag, because those cost nothing.
        guard AppSettings.tagsIncomingMail else { return }
        guard isConnected, !isEnhancing else { return }
        isEnhancing = true
        defer { isEnhancing = false }

        // Anything already classified comes back from the cache for free.
        // Without this a pull-to-refresh discards every tag and pays to derive
        // them all over again.
        //
        // One write for the lot. Applied one at a time, a launch with a full
        // cache was five hundred redraws of every screen before the first
        // request had even gone out.
        let answered = locallyReplied
        write { list in
            for index in list.indices {
                guard list[index].aiSummary == nil,
                      let remoteID = list[index].remoteID,
                      let cached = ClassificationCache.entry(for: remoteID)
                else { continue }
                Self.applying(
                    AIService.Classification(cached),
                    to: &list[index],
                    hasReplied: answered.contains(remoteID)
                )
            }
        }

        // Ids rather than messages, and worked out once: the loop below reads
        // the live array each time round so that a message just given its
        // summary drops out of the next batch, and a filtered copy taken here
        // would keep sending the same fifteen forever.
        let eligible = Self.eligibleForAI(messages, tier: UsageStore.shared.spend?.tier)
        func allowed(_ message: Message) -> Bool { eligible?.contains(message.id) ?? true }

        var budget = Self.enhancePassLimit
        while budget > 0 {
            let firstTier = messages
                .filter { allowed($0) && $0.mailbox != .sent && $0.aiSummary == nil && !$0.tags.contains(.noReplyNeeded) }
                .prefix(limit)
            // Messages the first tier already flagged whose second read never
            // ran -- the app was closed, the call failed -- and sent mail,
            // which goes straight to the second tier.
            let secondTier = messages
                .filter { message in
                    guard allowed(message),
                          let remoteID = message.remoteID, !facts.hasExtracted(remoteID)
                    else { return false }
                    if message.mailbox == .sent { return true }
                    return ClassificationCache.entry(for: remoteID)?.extract == true
                }
                .prefix(max(0, limit - firstTier.count))

            guard !firstTier.isEmpty || !secondTier.isEmpty else { break }
            budget -= firstTier.count + secondTier.count

            let landed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for message in firstTier {
                    group.addTask { await self.classifyAndExtract(message) }
                }
                for message in secondTier {
                    group.addTask { await self.extractFacts(from: message) }
                }
                var count = 0
                for await ok in group where ok { count += 1 }
                return count
            }
            // Written once per batch. Per message it was an encode of five
            // hundred entries and a UserDefaults write each time, which cost
            // more than the classification it was saving.
            ClassificationCache.flush()

            // A batch where nothing came back is the service being down, not
            // the mail being hard. The same fifteen would be sent again
            // until the budget ran out; stop and let the next refresh try.
            guard landed > 0 else { break }
        }
    }

    /// The most messages one pass will send to the model. A first import is
    /// a few thousand; twenty batches of fifteen is a couple of minutes in
    /// the background, and the next refresh picks up where it stopped.
    static let enhancePassLimit = 300

    /// How much of a mailbox the free tier sorts: the newest thousand at
    /// import, and everything that arrives after, which is newest by
    /// definition.
    static let freeSortingDepth = 1000

    /// Which messages the plan lets the model read, as ids. Nil means all.
    ///
    /// ⚠️ Not enforcement -- the ceiling on the server is that. This is about
    /// what the free allowance is *spent on*. Left alone, an import spent the
    /// whole thirty cents on the oldest mail in the box and had nothing left
    /// for the message that arrived this morning, which is the one that
    /// matters. Free sorts the newest thousand and then whatever comes in.
    /// Paid plans sort everything, and so does a plan not yet known: the
    /// answer arrives a moment after launch, and a first pass of three
    /// hundred is a cent.
    static func eligibleForAI(_ messages: [Message], tier: Plan?) -> Set<Message.ID>? {
        guard tier == .free else { return nil }
        let newest = messages.sorted { $0.date > $1.date }.prefix(freeSortingDepth)
        return Set(newest.map(\.id))
    }

    /// First tier, then the second where the first asked for it. False when
    /// the service did not answer.
    private func classifyAndExtract(_ message: Message) async -> Bool {
        let stamp = epoch
        guard let classification = try? await AIService.classify(message) else { return false }
        // Fifteen of these are in flight at once and each writes a tag and a
        // summary onto a message. A batch that lands after a switch would
        // write the previous mailbox's classifications into this one's mail
        // and then save the mixture, with nothing afterwards able to tell
        // which came from where.
        guard isCurrent(stamp) else { return false }
        apply(classification, to: message.id)
        guard let remoteID = message.remoteID else { return true }
        ClassificationCache.store(classification, for: remoteID)

        if classification.wantsExtraction {
            _ = await extractFacts(from: message)
        } else {
            // Nothing to find, on the model's word. Marked read so the sent
            // mail path and the retry path never send it again.
            facts.record([], from: remoteID)
        }
        return true
    }

    /// Second tier: what this message committed people to, turned round to
    /// the reader's side and kept on the phone. False when the service did
    /// not answer.
    private func extractFacts(from message: Message) async -> Bool {
        guard let remoteID = message.remoteID, let account else { return false }
        let stamp = epoch
        guard let extraction = try? await AIService.extract(message) else { return false }
        // `facts` is rebound to the new mailbox's file on a switch, so a late
        // extraction would write one mailbox's commitments into another's.
        guard isCurrent(stamp) else { return false }
        let found = extraction.facts(for: message, myAddress: account.address)
        facts.record(found, from: remoteID)
        if !found.isEmpty {
            Analytics.record(.factsExtracted, [
                "count": .int(found.count),
                "sent": .bool(message.mailbox == .sent),
            ])
        }
        return true
    }

    /// The model owns priority; the rules keep everything they can see that it
    /// cannot -- starred, unread, bulk headers.
    private func apply(_ classification: AIService.Classification, to id: Message.ID) {
        // A refresh re-classifies, and the model would happily decide again
        // that an answered email needs answering. What the person did here
        // outranks what the model thinks.
        let answered = message(id).map { hasReplied(to: $0) } ?? false
        update(id) { Self.applying(classification, to: &$0, hasReplied: answered) }
    }

    /// The rules themselves, on a message rather than on an id, so a whole
    /// cached backlog can go on in one write instead of one write each.
    private static func applying(
        _ classification: AIService.Classification,
        to message: inout Message,
        hasReplied: Bool
    ) {
        message.aiSummary = classification.summary

        if let tag = classification.tag {
            message.tags.subtract([.urgent, .veryImportant, .important])
            message.tags.insert(tag)
        }

        if classification.needsReply && !hasReplied {
            message.tags.insert(.needsReply)
        } else {
            message.tags.remove(.needsReply)
        }

        // What sort of thing it is, independent of how much it matters.
        // At most one, so clear any previous kind before setting.
        if let kind = classification.kindTag {
            message.tags.subtract(Set(AITag.kinds))
            message.tags.insert(kind)
        }

        // Never leave a message untagged; it would appear in no filter.
        if message.tags.isEmpty { message.tags.insert(.noReplyNeeded) }
    }

    /// Removes the mailbox in front of you, and everything derived from it.
    ///
    /// Scoped now. It used to name no mailbox, which was fine when there was
    /// one and destructive with two: five stores wipe themselves on this
    /// notice, so an unnamed one wiped every mailbox's chats, searches, facts
    /// and attachments to remove a single account.
    func disconnect() {
        guard let going = account else { return }

        // Tell Google to stop, then end the grant. That order is not
        // negotiable: revoking first makes the stop call impossible, which is
        // how Gmail ends up publishing notices for a mailbox the app dropped
        // for the next seven days. `stopWatching` existed for this and was
        // never once called.
        Task {
            if going.canPush,
               let token = try? await TokenBroker.shared.accessToken(for: going) {
                try? await GmailService.stopWatching(accessToken: token)
            }
            await TokenBroker.shared.revoke(going)
        }

        // Everything this mailbox holds, in its own suite and its own folder.
        // Cleared before the record goes, because the clearing is scoped to
        // the record.
        write { $0 = [] }
        MessageArchive.clear(mailbox: going.id)
        readCache = []
        repliedCache = []
        MailboxScope.defaults.removeObject(forKey: Self.readKey)
        MailboxScope.defaults.removeObject(forKey: Self.repliedKey)
        // The next mailbox starts its own history, and resuming from the
        // old one would ask Gmail about somebody else's log.
        syncCursor = nil
        hasImported = false
        // The next mailbox owes nothing on this one's behalf.
        ImportLedger.clear()
        ClassificationCache.clear()
        SnoozeStore.clearAll()
        // Vectors are derived from message content, so they go with it. A
        // signed-out mailbox leaves nothing behind, not even as numbers.
        SemanticIndex.forgetEverything()

        importProgress = .idle
        importAudit = nil
        lastVerifiedAt = nil
        connectionError = nil
        account = nil

        // Stop the phone being woken for a mailbox the app no longer has.
        // `stopWatching` above asks Gmail to stop publishing; this drops the
        // row that says where to send it if it publishes anyway. Neither is
        // enough on its own -- stopWatching is best-effort and swallows its
        // errors, so a failure there leaves Pub/Sub firing at a device row
        // that still exists.
        PushDelegate.push?.forget(going)

        // The registry deletes the record, the credentials, the suite and the
        // files, and posts the notice naming this mailbox -- which is what
        // lets the other stores tell "mine" from "somebody else's".
        registry.forget(going.id)

        // Whatever is left, if anything, becomes the one in front of you.
        if let next = registry.opening {
            account = next
            registry.setActive(next.id)
            MailboxScope.activate(next.id)
        }
    }

    // MARK: - Reading

    /// Messages in a mailbox, narrowed by an optional AI tag, unread state and
    /// search text.
    /// The list a screen shows. Sorted and thread-collapsed once in
    /// `MailboxIndex`, so this is a filter over an ordered list rather than
    /// its own sort -- and with no tag, query or unread filter it is the
    /// cached list itself.
    func messages(
        in mailbox: Mailbox,
        tag: AITag? = nil,
        unreadOnly: Bool = false,
        matching query: String = ""
    ) -> [Message] {
        let list = derived.byMailbox[mailbox] ?? []
        guard tag != nil || unreadOnly || !query.isEmpty else { return list }

        return list
            .filter { message in
                guard let tag else { return true }
                return message.tags.contains(tag)
            }
            .filter { !unreadOnly || !$0.isRead }
            .filter { query.isEmpty || $0.matches(query) }
    }

    /// Unread conversations. Read straight off the index, because this is
    /// what the tab badge asks for on every draw.
    func unreadCount(in mailbox: Mailbox) -> Int {
        derived.unread[mailbox] ?? 0
    }

    /// How many messages in a mailbox carry a given tag. Drives the chip counts.
    func count(of tag: AITag, in mailbox: Mailbox) -> Int {
        tagCounts(in: mailbox).total[tag] ?? 0
    }

    /// How many *unread* messages carry a tag. This is what the filter pills
    /// display: the number is a to-do count, so reading or answering
    /// everything urgent takes "Very Urgent 49" down to nothing instead of
    /// leaving a stale 49 pinned over a handled inbox.
    func unreadCount(of tag: AITag, in mailbox: Mailbox) -> Int {
        tagCounts(in: mailbox).unread[tag] ?? 0
    }

    /// Every tag's total and unread count in one pass over the mailbox.
    ///
    /// The filter bar needs both for all ten tags, and asking `count(of:)`
    /// and `unreadCount(of:)` per tag sorted the whole mailbox twenty times
    /// on every render. One sort, one walk.
    struct TagCounts {
        var total: [AITag: Int] = [:]
        var unread: [AITag: Int] = [:]
    }

    func tagCounts(in mailbox: Mailbox) -> TagCounts {
        derived.tagCounts[mailbox] ?? TagCounts()
    }

    /// Only the tags that actually appear in this mailbox, so the filter bar
    /// never offers a chip that would empty the list.
    ///
    /// One lookup, not ten. This used to ask `count(of:)` per tag, and each
    /// of those sorted the whole mailbox.
    func availableTags(in mailbox: Mailbox) -> [AITag] {
        let counts = tagCounts(in: mailbox)
        return AITag.allCases.filter { (counts.total[$0] ?? 0) > 0 }
    }

    func message(_ id: Message.ID) -> Message? {
        guard let index = positions[id], index < messages.count else { return nil }
        return messages[index]
    }

    // MARK: - Writing

    /// Messages read inside Maily.
    ///
    /// Without `gmail.modify` there is no way to tell Gmail about it, and a
    /// refresh brings Gmail's UNREAD label back with it -- so every message
    /// just read would turn bold again. Remembering it here is what makes
    /// reading stick, and it is why `merge` prefers this over what Gmail says.
    private static let readKey = "mail.readLocally"

    /// Kept in memory, like the classification cache and for the same
    /// reason: this is read once per message inside loops over the whole
    /// mailbox, and each read was a UserDefaults fetch and a fresh Set.
    @ObservationIgnored private var readCache: Set<String>?

    private var locallyRead: Set<String> {
        get {
            if let readCache { return readCache }
            let loaded = Set(MailboxScope.defaults.stringArray(forKey: Self.readKey) ?? [])
            readCache = loaded
            return loaded
        }
        set {
            readCache = newValue
            MailboxScope.defaults.set(Array(newValue), forKey: Self.readKey)
        }
    }

    /// Messages answered inside Maily.
    ///
    /// `needsReply` was written once, when the model first read a message,
    /// and nothing ever took it off again. So an email stayed "Needs Reply"
    /// after the reply had gone: the chip count never came down, and the
    /// assistant kept asking for something already done. This is the same
    /// trick as `readKey` -- remember it here, because Gmail cannot be told.
    private static let repliedKey = "mail.repliedLocally"

    @ObservationIgnored private var repliedCache: Set<String>?

    private var locallyReplied: Set<String> {
        get {
            if let repliedCache { return repliedCache }
            let loaded = Set(MailboxScope.defaults.stringArray(forKey: Self.repliedKey) ?? [])
            repliedCache = loaded
            return loaded
        }
        set {
            repliedCache = newValue
            MailboxScope.defaults.set(Array(newValue), forKey: Self.repliedKey)
        }
    }

    /// The reply has gone, so this no longer needs one. Answering something
    /// also means you read it.
    func markReplied(_ id: Message.ID) {
        if let remoteID = message(id)?.remoteID {
            locallyReplied.insert(remoteID)
        }
        markRead(id)
        update(id) { $0.tags.remove(.needsReply) }
    }

    /// True when this was answered from here, whatever a later
    /// classification pass decides.
    func hasReplied(to message: Message) -> Bool {
        guard let remoteID = message.remoteID else { return false }
        return locallyReplied.contains(remoteID)
    }

    func markRead(_ id: Message.ID, _ isRead: Bool = true) {
        if let remoteID = message(id)?.remoteID {
            var read = locallyRead
            if isRead { read.insert(remoteID) } else { read.remove(remoteID) }
            locallyRead = read
        }
        update(id) { $0.isRead = isRead }
    }

    /// Marks a batch read in one pass, and hands back only the ones it
    /// actually changed -- which is what "undo" needs, and what stops the
    /// assistant claiming it read twelve when eleven were read already.
    @discardableResult
    func markRead(_ ids: [Message.ID], _ isRead: Bool = true) -> [Message.ID] {
        let changed = ids.filter { id in
            guard let message = message(id) else { return false }
            return message.isRead != isRead
        }
        for id in changed { markRead(id, isRead) }
        return changed
    }

    /// Applies what the user has read and answered here on top of what Gmail
    /// reported. Gmail sends UNREAD back on every refresh and the classifier
    /// re-asserts `needsReply`, so without this both would undo themselves.
    /// Takes the list rather than the property, so it can run inside a
    /// `write` that is already holding it. Two nested writes to the same
    /// array would be an exclusivity violation, not a slow path.
    private static func applyLocalReadState(
        to list: inout [Message], read: Set<String>, replied: Set<String>
    ) {
        guard !read.isEmpty || !replied.isEmpty else { return }
        for index in list.indices {
            guard let remoteID = list[index].remoteID else { continue }
            if read.contains(remoteID) { list[index].isRead = true }
            if replied.contains(remoteID) { list[index].tags.remove(.needsReply) }
        }
    }

    func toggleFlag(_ id: Message.ID) {
        update(id) { $0.isFlagged.toggle() }
    }

    func move(_ id: Message.ID, to mailbox: Mailbox) {
        update(id) { $0.mailbox = mailbox }
    }

    /// Trashing something already in the trash deletes it for good.
    func delete(_ id: Message.ID) {
        guard let message = message(id) else { return }
        if message.mailbox == .trash {
            write { $0.removeAll { $0.id == id } }
        } else {
            move(id, to: .trash)
        }
    }

    /// Sends through Gmail, and only records it locally once Gmail has taken
    /// it. Throws so the compose sheet can stay open and show what went wrong
    /// -- an email that silently fails to send is the worst outcome here.
    func send(
        subject: String,
        to address: String,
        cc: String? = nil,
        bcc: String? = nil,
        body: String,
        html: String? = nil,
        attachments: [MIMEBuilder.Attached] = [],
        replyingTo original: Message? = nil
    ) async throws {
        guard let account else { throw SendError.notConnected }
        try checkSize(of: attachments)
        let stamp = epoch

        let envelope = MIMEBuilder.Envelope(
            from: MIMEBuilder.address(name: account.displayName, email: account.address),
            to: address,
            cc: cc,
            bcc: bcc,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            plainText: body,
            html: html,
            inReplyTo: original?.messageIDHeader,
            references: original?.messageIDHeader,
            attachments: attachments
        )

        let sent: SentReceipt
        if account.provider == .imap {
            // SMTP, on a different host, with possibly a different password --
            // and it files its own copy in Sent, which Gmail does for free.
            guard let backend else { throw SendError.notConnected }
            sent = try await backend.send(
                envelope,
                inThread: original?.threadID.map(ThreadRef.init)
            )
        } else {
            let token = try await accessToken()
            let receipt = try await GmailService.send(
                accessToken: token,
                envelope: envelope,
                threadID: original?.threadID
            )
            sent = SentReceipt(id: receipt.id, thread: receipt.threadID)
        }

        var local = Message(
            sender: Contact(name: account.displayName, address: account.address),
            recipients: [Contact(name: address, address: address)],
            subject: subject.isEmpty ? "(No Subject)" : subject,
            body: body,
            date: .now,
            isRead: true,
            mailbox: .sent,
            tags: [.noReplyNeeded]
        )
        local.remoteID = sent.id
        local.threadID = sent.thread
        local.hasAttachment = !attachments.isEmpty

        // The message went from the mailbox that is still in front of the
        // person, so it goes in that mailbox's Sent. If they switched while
        // it was uploading, it is Gmail's copy that is authoritative and the
        // next sync of *that* account will bring it down where it belongs --
        // appending it here would file it under the wrong address.
        guard isCurrent(stamp) else { return }
        write { $0.append(local) }
    }

    /// Refuses before anything is uploaded, so nobody watches a progress
    /// spinner for a minute to be told no at the end.
    private func checkSize(of attachments: [MIMEBuilder.Attached]) throws {
        let total = attachments.reduce(0) { $0 + $1.size }
        guard total <= MIMEBuilder.attachmentLimit else {
            throw SendError.attachmentsTooLarge(MIMEBuilder.attachmentLimit)
        }
    }

    /// Writes a real Gmail draft, so it is there in Gmail on every device and
    /// not just in this app's memory.
    ///
    /// Pass `replacing` to save over one that already exists rather than
    /// leaving the old copy behind. Reopening a draft, changing a line and
    /// saving is the common case, and two drafts of the same message is not
    /// what anybody meant by it.
    func saveDraft(
        subject: String,
        to address: String,
        cc: String? = nil,
        bcc: String? = nil,
        body: String,
        html: String? = nil,
        attachments: [MIMEBuilder.Attached] = [],
        replyingTo original: Message? = nil,
        replacing existing: Message? = nil
    ) async throws {
        guard let account else { throw SendError.notConnected }
        try checkSize(of: attachments)
        let stamp = epoch

        let token = try await accessToken()
        let envelope = MIMEBuilder.Envelope(
            from: MIMEBuilder.address(name: account.displayName, email: account.address),
            to: address,
            cc: cc,
            bcc: bcc,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            plainText: body,
            html: html,
            inReplyTo: original?.messageIDHeader,
            references: original?.messageIDHeader,
            attachments: attachments
        )

        // Editing one that exists replaces it in place, so the id everything
        // else holds stays valid.
        if let existing, let draftID = try await draftID(of: existing, token: token) {
            try await GmailService.updateDraft(
                accessToken: token,
                id: draftID,
                envelope: envelope,
                threadID: existing.threadID ?? original?.threadID
            )
            guard isCurrent(stamp) else { return }
            update(existing.id) {
                $0.subject = subject.isEmpty ? "(No Subject)" : subject
                $0.recipients = [Contact(name: address, address: address)]
                $0.body = body
                $0.htmlBody = html
                $0.date = .now
                $0.draftID = draftID
            }
            return
        }

        let handle = try await GmailService.createDraft(
            accessToken: token,
            envelope: envelope,
            threadID: original?.threadID
        )

        var local = Message(
            sender: Contact(name: account.displayName, address: account.address),
            recipients: [Contact(name: address, address: address)],
            subject: subject.isEmpty ? "(No Subject)" : subject,
            body: body,
            date: .now,
            isRead: true,
            mailbox: .drafts
        )
        // The message id, not the draft id. They are different numbers, and
        // everything outside the draft endpoints wants this one.
        local.remoteID = handle.message
        local.threadID = handle.thread
        local.draftID = handle.draft
        local.htmlBody = html

        // Same rule as a send: the draft is on Gmail either way, and the
        // mailbox it belongs to will bring it down. Appending it here after
        // a switch would file it under the wrong address.
        guard isCurrent(stamp) else { return }
        write { $0.append(local) }
    }

    /// Throws a draft away here and on Gmail.
    ///
    /// Unlike deleting mail, this is real and permanent -- `gmail.compose`
    /// covers drafts, and a draft in the trash is not a thing Gmail has. The
    /// row goes either way: a draft that failed to delete remotely but stayed
    /// on screen is worse than one that comes back on the next refresh.
    func discardDraft(_ id: Message.ID) async {
        guard let message = message(id), message.mailbox == .drafts else { return }
        write { $0.removeAll { $0.id == id } }

        do {
            let token = try await accessToken()
            guard let draftID = try await draftID(of: message, token: token) else { return }
            try await GmailService.deleteDraft(accessToken: token, id: draftID)
        } catch {
            sendFailure = "The draft is gone from here, but Gmail kept it. \(error.localizedDescription)"
        }
    }

    /// A draft's own id, looked up once and remembered.
    private func draftID(of message: Message, token: String) async throws -> String? {
        if let known = message.draftID { return known }
        guard let remoteID = message.remoteID else { return nil }

        let found = try await GmailService.draftID(accessToken: token, forMessage: remoteID)
        if let found { update(message.id) { $0.draftID = found } }
        return found
    }

    enum SendError: LocalizedError {
        case notConnected
        case attachmentsTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                "Connect a Gmail account before sending."
            case .attachmentsTooLarge(let limit):
                // Said with the number in it, because "too large" without one
                // leaves somebody removing files at random.
                "The files add up to more than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)). Remove one, or send it as a link."
            }
        }
    }

    private func update(_ id: Message.ID, _ change: (inout Message) -> Void) {
        guard let index = positions[id], index < messages.count else { return }
        write { change(&$0[index]) }
    }
}

private extension Message {
    func matches(_ query: String) -> Bool {
        [subject, body, sender.name, sender.address]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
