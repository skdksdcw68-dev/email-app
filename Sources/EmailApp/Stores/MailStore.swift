import Foundation
import Observation

@Observable
@MainActor
final class MailStore {
    /// `nil` until the user connects Gmail. Everything in the Mail tab keys off this.
    private(set) var account: GmailAccount?
    private(set) var messages: [Message]
    private(set) var isConnecting = false
    private(set) var isRefreshing = false
    private(set) var isEnhancing = false
    /// Surfaced in the UI rather than swallowed -- a declined consent screen
    /// or an expired grant must be visible, not a silently empty inbox.
    private(set) var connectionError: String?

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

    func notePreferencesChanged() {
        preferencesVersion += 1
    }

    var isConnected: Bool { account != nil }
    var hasMoreMail: Bool { nextPageToken != nil }
    /// The very first load, when there is nothing to show yet. Drives the
    /// skeleton list rather than an empty screen.
    var isLoadingFirstPage: Bool { (isConnecting || isRefreshing) && messages.isEmpty }
    /// How many pages to pull at a time. Each id costs a second request for
    /// the full message, so a bigger page is a lot more requests in flight.
    static let pageSize = 25
    /// Larger during the one-off import: the user is watching a progress bar
    /// and waiting, so throughput matters more than responsiveness.
    static let importPageSize = 50

    /// Where the one-time import has got to. Drives the import screen.
    private(set) var importProgress: ImportProgress = .idle
    /// Set once the three-month import has completed, so it never runs twice.
    var hasImported: Bool {
        get { UserDefaults.standard.bool(forKey: "mail.hasImported") }
        set { UserDefaults.standard.set(newValue, forKey: "mail.hasImported") }
    }

    private static let accountKey = "mail.account"

    init(account: GmailAccount? = nil, messages: [Message] = []) {
        // A previously connected mailbox is remembered so a cold launch does
        // not present the connect screen to someone already signed in.
        if let account {
            self.account = account
        } else if let data = UserDefaults.standard.data(forKey: Self.accountKey) {
            self.account = try? JSONDecoder().decode(GmailAccount.self, from: data)
        }
        self.messages = messages
    }

    private func persistAccount() {
        guard let account, let data = try? JSONEncoder().encode(account) else {
            UserDefaults.standard.removeObject(forKey: Self.accountKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.accountKey)
    }

    /// Called at launch. Re-establishes the Google session without a consent
    /// screen and pulls fresh mail; falls back to the connect screen only if
    /// the grant is genuinely gone.
    func restore() async {
        guard isConnected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let session = await AuthService.restoreGmail() else {
            // The grant was revoked or expired beyond recovery.
            account = nil
            persistAccount()
            return
        }

        account = GmailAccount(
            email: session.email,
            displayName: session.displayName,
            connectedAt: account?.connectedAt ?? .now
        )
        persistAccount()

        // An import that was interrupted -- the app killed partway through --
        // leaves a partial mailbox that would otherwise never be completed,
        // because the import only ever ran from connect().
        guard hasImported else {
            await importRecentMail()
            return
        }

        if let page = try? await GmailService.fetchInbox(
            accessToken: session.accessToken, limit: Self.pageSize
        ) {
            merge(page.messages)
            self.nextPageToken = page.nextPageToken
            let snapshot = messages
            Task { await MessageArchive.save(snapshot) }
            Task { await enhanceWithAI() }
        }
    }

    // MARK: - Connection

    /// Connects a real mailbox and pulls recent inbox mail.
    ///
    /// Runs entirely on the device -- Gmail data never passes through a server
    /// of ours. That is both less to build and a materially lower CASA risk
    /// profile, since the assessment trigger is an app able to reach restricted
    /// data "from or through a third-party server".
    func connect() async {
        guard !isConnecting, !isConnected else { return }
        isConnecting = true
        connectionError = nil
        importProgress = .connecting
        defer { isConnecting = false }

        do {
            let session = try await AuthService.connectGmail()
            account = GmailAccount(
                email: session.email,
                displayName: session.displayName,
                connectedAt: .now
            )
            persistAccount()
            await importRecentMail()
        } catch {
            connectionError = error.localizedDescription
            account = nil
        }
    }

    /// Re-pulls the inbox with a refreshed token. Pull-to-refresh, for now;
    /// incremental History API sync comes with the backend.
    func refresh() async {
        guard isConnected, !isRefreshing else { return }
        isRefreshing = true
        connectionError = nil
        defer { isRefreshing = false }

        do {
            let token = try await AuthService.currentGmailAccessToken()
            let page = try await GmailService.fetchInbox(accessToken: token, limit: Self.pageSize)
            merge(page.messages)
            nextPageToken = page.nextPageToken
            let snapshot = messages
            Task { await MessageArchive.save(snapshot) }
            Task { await enhanceWithAI() }
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Pulls three months of mail, page by page, reporting real progress.
    ///
    /// Runs once, when a mailbox is first connected. After this the archive on
    /// disk is the starting point and refresh only tops it up.
    func importRecentMail() async {
        guard isConnected else { return }
        importProgress = .counting

        var collected: [Message] = []
        var seen = Set<String>()
        var token: String?
        // Gmail does not report a total up front, so the denominator only
        // becomes real once a page comes back short -- until then the count
        // is honest about being a running tally rather than a fraction.
        var knownTotal = 0

        repeat {
            do {
                let accessToken = try await AuthService.currentGmailAccessToken()
                let page = try await GmailService.fetchInbox(
                    accessToken: accessToken,
                    limit: Self.importPageSize,
                    pageToken: token,
                    query: GmailService.importWindow
                )

                for message in page.messages {
                    guard let remoteID = message.remoteID else {
                        collected.append(message)
                        continue
                    }
                    if seen.insert(remoteID).inserted { collected.append(message) }
                }

                token = page.nextPageToken
                // On the last page the total is known exactly. Before that,
                // assume at least one more page so the bar never sits at 100%
                // with work still to do.
                knownTotal = token == nil ? collected.count : collected.count + Self.importPageSize
                importProgress = .importing(done: collected.count, total: knownTotal)

                // Deliberately NOT publishing `messages` here. Assigning the
                // growing array every page made the list rebuild itself at 50,
                // 100, 500, 1000 rows while the import was still running, and
                // on a real mailbox that locks the phone up. The counter is
                // the live feedback; the mail lands once, at the end.
            } catch {
                connectionError = error.localizedDescription
                break
            }
        } while token != nil

        // Sent mail, in one page rather than the full window. It is not for
        // reading -- it is what makes "waiting on their reply" answerable at
        // all, since that means a message you sent that nobody came back on.
        // gmail.readonly already covers SENT, so this costs no new scope.
        if let accessToken = try? await AuthService.currentGmailAccessToken(),
           let sent = try? await GmailService.fetchInbox(
               accessToken: accessToken,
               limit: Self.importPageSize,
               query: GmailService.importWindow,
               label: "SENT"
           ) {
            for message in sent.messages {
                guard let remoteID = message.remoteID else { continue }
                if seen.insert(remoteID).inserted { collected.append(message) }
            }
        }

        importProgress = .saving
        await MessageArchive.save(collected)

        // Everything arrives at once, after the progress screen has said it is
        // finishing. One layout pass instead of twenty.
        messages = collected
        applyLocalReadState()
        nextPageToken = nil
        importProgress = .finished(count: collected.count)
        hasImported = true
        Task { await enhanceWithAI() }
    }

    /// Folds a freshly fetched page into what is already held, rather than
    /// replacing it.
    ///
    /// Replacing was fine when the app only ever showed one page. With an
    /// archive of three months behind it, a refresh returning the newest 25
    /// would throw the rest away -- and take every AI tag with it.
    private func merge(_ fetched: [Message]) {
        var byRemoteID: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let remoteID = message.remoteID { byRemoteID[remoteID] = index }
        }

        for message in fetched {
            guard let remoteID = message.remoteID else {
                messages.append(message)
                continue
            }
            if let index = byRemoteID[remoteID] {
                // Keep what the model worked out; take everything else fresh,
                // so read state and flags follow Gmail.
                var updated = message
                updated.tags = messages[index].tags
                updated.aiSummary = messages[index].aiSummary
                messages[index] = updated
            } else {
                messages.append(message)
                byRemoteID[remoteID] = messages.count - 1
            }
        }

        applyLocalReadState()
    }

    /// Restores the archive so a cold launch has mail on screen before any
    /// network call finishes.
    func loadArchive() async {
        guard messages.isEmpty else { return }
        let stored = await MessageArchive.load()
        guard !stored.isEmpty, messages.isEmpty else { return }
        messages = stored
        applyLocalReadState()
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

        do {
            let accessToken = try await AuthService.currentGmailAccessToken()
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

            messages.append(contentsOf: fresh)
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

        guard let classification = try? await AIService.classify(message) else { return }
        apply(classification, to: id)
        if let remoteID = message.remoteID {
            ClassificationCache.store(classification, for: remoteID)
        }
    }

    /// Conversations waiting on somebody, in either direction.
    var followUps: [FollowUp] {
        guard let account else { return [] }
        return messages.followUps(myAddress: account.email)
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

        let scored = messages.map { message -> (message: Message, keyword: Int, total: Int) in
            var keyword = 0

            if !words.isEmpty {
                let haystack = "\(message.subject) \(message.sender.name) \(message.body.prefix(400))".lowercased()
                keyword = words.filter(haystack.contains).count * 10
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

        return scored
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .prefix(limit)
            .map(\.message)
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
    ]

    private static let stopWords: Set<String> = [
        "what", "which", "there", "their", "about", "should", "would", "could",
        "have", "this", "that", "with", "from", "they", "them", "been", "were",
        "does", "email", "emails", "mail", "maily", "please", "show",
    ]

    /// How many messages share this one's conversation. 1 means it stands alone.
    func threadCount(for message: Message) -> Int {
        guard let thread = message.threadID else { return 1 }
        return messages.filter { $0.threadID == thread }.count
    }

    /// Second pass over the mailbox: the model reads what the rules could only
    /// guess at, and replaces the priority it inferred.
    ///
    /// Bulk mail is skipped entirely. The rules already settled it from a
    /// List-Unsubscribe header, and it is the largest bucket -- not paying to
    /// have a model confirm that a newsletter is a newsletter is most of the
    /// cost saving.
    func enhanceWithAI(limit: Int = 15) async {
        // The setting is real: off means nothing leaves the device and nothing
        // is charged. Local rules still tag, because those cost nothing.
        guard AppSettings.tagsIncomingMail else { return }
        guard isConnected, !isEnhancing else { return }
        isEnhancing = true
        defer { isEnhancing = false }

        // Anything already classified comes back from the cache for free.
        // Without this a pull-to-refresh discards every tag and pays to derive
        // them all over again.
        for message in messages {
            guard message.aiSummary == nil,
                  let remoteID = message.remoteID,
                  let cached = ClassificationCache.entry(for: remoteID)
            else { continue }
            apply(AIService.Classification(cached), to: message.id)
        }

        let targets = messages
            .filter { $0.aiSummary == nil && !$0.tags.contains(.noReplyNeeded) }
            .prefix(limit)
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: (Message.ID, AIService.Classification?).self) { group in
            for message in targets {
                group.addTask { (message.id, try? await AIService.classify(message)) }
            }
            for await (id, classification) in group {
                guard let classification else { continue }
                apply(classification, to: id)
                if let remoteID = message(id)?.remoteID {
                    ClassificationCache.store(classification, for: remoteID)
                }
            }
        }
    }

    /// The model owns priority; the rules keep everything they can see that it
    /// cannot -- starred, unread, bulk headers.
    private func apply(_ classification: AIService.Classification, to id: Message.ID) {
        // A refresh re-classifies, and the model would happily decide again
        // that an answered email needs answering. What the person did here
        // outranks what the model thinks.
        let answered = message(id).map { hasReplied(to: $0) } ?? false

        update(id) { message in
            message.aiSummary = classification.summary

            if let tag = classification.tag {
                message.tags.subtract([.urgent, .veryImportant, .important])
                message.tags.insert(tag)
            }

            if classification.needsReply && !answered {
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
    }

    func disconnect() {
        // Anything else holding mail content on disk (chat history) clears
        // itself on this.
        NotificationCenter.default.post(name: .mailboxDisconnected, object: nil)
        account = nil
        messages = []
        MessageArchive.clear()
        UserDefaults.standard.removeObject(forKey: Self.readKey)
        UserDefaults.standard.removeObject(forKey: Self.repliedKey)
        hasImported = false
        importProgress = .idle
        connectionError = nil
        persistAccount()
        ClassificationCache.clear()
    }

    // MARK: - Reading

    /// Messages in a mailbox, narrowed by an optional AI tag, unread state and
    /// search text.
    func messages(
        in mailbox: Mailbox,
        tag: AITag? = nil,
        unreadOnly: Bool = false,
        matching query: String = ""
    ) -> [Message] {
        messages
            .filter { mailbox.isSmart ? $0.isFlagged && $0.mailbox != .trash : $0.mailbox == mailbox }
            .filter { message in
                guard let tag else { return true }
                return message.tags.contains(tag)
            }
            .filter { !unreadOnly || !$0.isRead }
            .filter { query.isEmpty || $0.matches(query) }
            .sorted { $0.date > $1.date }
            .collapsingThreads()
    }

    func unreadCount(in mailbox: Mailbox) -> Int {
        messages(in: mailbox).filter { !$0.isRead }.count
    }

    /// How many messages in a mailbox carry a given tag. Drives the chip counts.
    func count(of tag: AITag, in mailbox: Mailbox) -> Int {
        messages(in: mailbox, tag: tag).count
    }

    /// How many *unread* messages carry a tag. This is what the filter pills
    /// display: the number is a to-do count, so reading or answering
    /// everything urgent takes "Very Urgent 49" down to nothing instead of
    /// leaving a stale 49 pinned over a handled inbox.
    func unreadCount(of tag: AITag, in mailbox: Mailbox) -> Int {
        messages(in: mailbox, tag: tag, unreadOnly: true).count
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
        var counts = TagCounts()
        for message in messages(in: mailbox) {
            for tag in message.tags {
                counts.total[tag, default: 0] += 1
                if !message.isRead { counts.unread[tag, default: 0] += 1 }
            }
        }
        return counts
    }

    /// Only the tags that actually appear in this mailbox, so the filter bar
    /// never offers a chip that would empty the list.
    func availableTags(in mailbox: Mailbox) -> [AITag] {
        AITag.allCases.filter { count(of: $0, in: mailbox) > 0 }
    }

    func message(_ id: Message.ID) -> Message? {
        messages.first { $0.id == id }
    }

    // MARK: - Writing

    /// Messages read inside Maily.
    ///
    /// Without `gmail.modify` there is no way to tell Gmail about it, and a
    /// refresh brings Gmail's UNREAD label back with it -- so every message
    /// just read would turn bold again. Remembering it here is what makes
    /// reading stick, and it is why `merge` prefers this over what Gmail says.
    private static let readKey = "mail.readLocally"

    private var locallyRead: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.readKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.readKey) }
    }

    /// Messages answered inside Maily.
    ///
    /// `needsReply` was written once, when the model first read a message,
    /// and nothing ever took it off again. So an email stayed "Needs Reply"
    /// after the reply had gone: the chip count never came down, and the
    /// assistant kept asking for something already done. This is the same
    /// trick as `readKey` -- remember it here, because Gmail cannot be told.
    private static let repliedKey = "mail.repliedLocally"

    private var locallyReplied: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.repliedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.repliedKey) }
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
    private func applyLocalReadState() {
        let read = locallyRead
        let replied = locallyReplied
        guard !read.isEmpty || !replied.isEmpty else { return }
        for index in messages.indices {
            guard let remoteID = messages[index].remoteID else { continue }
            if read.contains(remoteID) { messages[index].isRead = true }
            if replied.contains(remoteID) { messages[index].tags.remove(.needsReply) }
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
            messages.removeAll { $0.id == id }
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
        body: String,
        html: String? = nil,
        replyingTo original: Message? = nil
    ) async throws {
        guard let account else { throw SendError.notConnected }

        let token = try await AuthService.currentGmailAccessToken()
        let envelope = MIMEBuilder.Envelope(
            from: MIMEBuilder.address(name: account.displayName, email: account.email),
            to: address,
            cc: cc,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            plainText: body,
            html: html,
            inReplyTo: original?.messageIDHeader,
            references: original?.messageIDHeader
        )

        let sent = try await GmailService.send(
            accessToken: token,
            envelope: envelope,
            threadID: original?.threadID
        )

        var local = Message(
            sender: Contact(name: account.displayName, address: account.email),
            recipients: [Contact(name: address, address: address)],
            subject: subject.isEmpty ? "(No Subject)" : subject,
            body: body,
            date: .now,
            isRead: true,
            mailbox: .sent,
            tags: [.noReplyNeeded]
        )
        local.remoteID = sent.id
        local.threadID = sent.threadID
        messages.append(local)
    }

    /// Writes a real Gmail draft, so it is there in Gmail on every device and
    /// not just in this app's memory.
    func saveDraft(
        subject: String,
        to address: String,
        cc: String? = nil,
        body: String,
        html: String? = nil,
        replyingTo original: Message? = nil
    ) async throws {
        guard let account else { throw SendError.notConnected }

        let token = try await AuthService.currentGmailAccessToken()
        let envelope = MIMEBuilder.Envelope(
            from: MIMEBuilder.address(name: account.displayName, email: account.email),
            to: address,
            cc: cc,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            plainText: body,
            html: html,
            inReplyTo: original?.messageIDHeader,
            references: original?.messageIDHeader
        )

        let id = try await GmailService.createDraft(
            accessToken: token,
            envelope: envelope,
            threadID: original?.threadID
        )

        var local = Message(
            sender: Contact(name: account.displayName, address: account.email),
            recipients: [Contact(name: address, address: address)],
            subject: subject.isEmpty ? "(No Subject)" : subject,
            body: body,
            date: .now,
            isRead: true,
            mailbox: .drafts
        )
        local.remoteID = id
        messages.append(local)
    }

    enum SendError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected: "Connect a Gmail account before sending."
            }
        }
    }

    private func update(_ id: Message.ID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
}

private extension Message {
    func matches(_ query: String) -> Bool {
        [subject, body, sender.name, sender.address]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
