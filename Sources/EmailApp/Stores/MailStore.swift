import Foundation
import Observation

@Observable
@MainActor
final class MailStore {
    /// `nil` until the user connects Gmail. Everything in the Mail tab keys off this.
    private(set) var account: GmailAccount?
    private(set) var messages: [Message]
    private(set) var isConnecting = false

    var isConnected: Bool { account != nil }

    init(account: GmailAccount? = nil, messages: [Message] = []) {
        self.account = account
        self.messages = messages
    }

    // MARK: - Connection

    /// Stubbed Gmail sign-in.
    ///
    /// Real OAuth replaces the sleep and the hardcoded account: sign in with
    /// Google, exchange for a token, fetch the profile, then page the Gmail API
    /// into `messages`. Nothing outside this method needs to change.
    func connect() async {
        guard !isConnecting, !isConnected else { return }
        isConnecting = true
        try? await Task.sleep(for: .seconds(1.2))

        account = GmailAccount(
            email: "abelamare1633@gmail.com",
            displayName: "Abel Amare",
            connectedAt: .now
        )
        messages = Message.samples
        isConnecting = false
    }

    func disconnect() {
        account = nil
        messages = []
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
