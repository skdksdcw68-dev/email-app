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
    /// Surfaced in the UI rather than swallowed -- a declined consent screen
    /// or an expired grant must be visible, not a silently empty inbox.
    private(set) var connectionError: String?

    var isConnected: Bool { account != nil }

    init(account: GmailAccount? = nil, messages: [Message] = []) {
        self.account = account
        self.messages = messages
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
        defer { isConnecting = false }

        do {
            let session = try await AuthService.connectGmail()
            account = GmailAccount(
                email: session.email,
                displayName: session.displayName,
                connectedAt: .now
            )
            messages = try await GmailService.fetchInbox(accessToken: session.accessToken)
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
            messages = try await GmailService.fetchInbox(accessToken: token)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func disconnect() {
        account = nil
        messages = []
        connectionError = nil
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
    }

    func unreadCount(in mailbox: Mailbox) -> Int {
        messages(in: mailbox).filter { !$0.isRead }.count
    }

    /// How many messages in a mailbox carry a given tag. Drives the chip counts.
    func count(of tag: AITag, in mailbox: Mailbox) -> Int {
        messages(in: mailbox, tag: tag).count
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

    func markRead(_ id: Message.ID, _ isRead: Bool = true) {
        update(id) { $0.isRead = isRead }
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

    func send(subject: String, to address: String, body: String) {
        let recipient = Contact(name: address, address: address)
        messages.append(
            Message(
                sender: .me,
                recipients: [recipient],
                subject: subject.isEmpty ? "(No Subject)" : subject,
                body: body,
                date: .now,
                isRead: true,
                mailbox: .sent,
                tags: [.noReplyNeeded]
            )
        )
    }

    /// Keeps an unsent message in Drafts. Local only for now -- writing a real
    /// Gmail draft is a POST to users.drafts, which gmail.compose does allow,
    /// so this is a seam rather than a dead end.
    func saveDraft(subject: String, to address: String, body: String) {
        let recipient = Contact(name: address, address: address)
        messages.append(
            Message(
                sender: .me,
                recipients: [recipient],
                subject: subject.isEmpty ? "(No Subject)" : subject,
                body: body,
                date: .now,
                isRead: true,
                mailbox: .drafts
            )
        )
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
