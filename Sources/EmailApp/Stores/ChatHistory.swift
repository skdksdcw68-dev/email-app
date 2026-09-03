import Foundation
import Observation

/// A saved conversation with Maily.
struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var turns: [ChatMessage]

    /// The opening question, cut to fit a row.
    static func title(for turns: [ChatMessage]) -> String {
        let first = turns.first { $0.role == .user }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else { return "New chat" }
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }

    /// The last thing Maily said, for the row underneath the title.
    var preview: String? {
        turns.last { $0.role == .assistant && !$0.text.isEmpty && !$0.failed }?.text
    }
}

extension Notification.Name {
    /// Posted when a mailbox is disconnected. Anything that keeps mail
    /// content on disk clears itself on this.
    static let mailboxDisconnected = Notification.Name("maily.mailboxDisconnected")

    /// Posted when a different mailbox becomes the one in front of you.
    /// Nothing is deleted -- the file-backed stores rebind to that mailbox's
    /// copy and reload.
    static let activeMailboxChanged = Notification.Name("maily.activeMailboxChanged")
}

/// Which mailbox a notice is about.
///
/// The disconnect notice used to carry nothing, which was fine when there was
/// one mailbox and is destructive with two: five stores wipe themselves on it,
/// and without an id every one of them wipes when *any* mailbox is removed.
///
/// A missing id still means "everything", because full sign-out really does
/// mean all of it.
enum MailboxNotice {
    static let key = "mailbox"

    static func id(in note: Notification) -> MailboxID? {
        guard let raw = note.userInfo?[key] as? String else { return nil }
        return MailboxID(rawValue: raw)
    }

    /// True when the notice names this mailbox, or names none at all.
    static func concerns(_ mine: MailboxID?, _ note: Notification) -> Bool {
        guard let named = id(in: note) else { return true }
        return named == mine
    }
}

/// Past conversations, kept on this phone only.
///
/// One JSON file in Application Support, rewritten whole on every change:
/// a conversation is a few kilobytes and there are rarely more than a few
/// dozen, so anything cleverer would be complexity without a benefit.
/// Conversations contain mail content, so the file goes with the mailbox:
/// disconnecting clears it.
@Observable
@MainActor
final class ChatHistory {
    /// Newest first.
    private(set) var conversations: [Conversation] = []

    /// Which mailbox's conversations these are. Nil when the store was handed
    /// an explicit file -- previews and tests -- and for the window before
    /// any mailbox exists.
    private(set) var boundMailbox: MailboxID?
    /// A `var` because the active mailbox can change under it. Rebound, never
    /// reconstructed: this object is in the environment, and replacing it
    /// tears down every view holding it.
    private(set) var fileURL: URL

    private static let fileName = "chats.json"

    /// Read in `deinit`, which is not on the main actor. The tokens are only
    /// ever written once, in `init`, so there is nothing to race.
    nonisolated(unsafe) private var disconnectObserver: NSObjectProtocol?
    nonisolated(unsafe) private var switchObserver: NSObjectProtocol?

    init(fileURL: URL? = nil, mailbox: MailboxID? = nil) {
        self.boundMailbox = mailbox
        self.fileURL = fileURL
            ?? mailbox.map { MailboxPaths.file(Self.fileName, for: $0) }
            ?? Self.defaultURL
        load()

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .mailboxDisconnected, object: nil, queue: .main
        ) { [weak self] note in
            let id = MailboxNotice.id(in: note)
            Task { @MainActor in self?.forget(mailbox: id) }
        }

        switchObserver = NotificationCenter.default.addObserver(
            forName: .activeMailboxChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = MailboxNotice.id(in: note) else { return }
            Task { @MainActor in self?.rebind(to: id) }
        }
    }

    deinit {
        for token in [disconnectObserver, switchObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// A mailbox went. Ours, or a full sign-out, means clear. Somebody else's
    /// means delete their file and leave what is on screen alone.
    private func forget(mailbox id: MailboxID?) {
        guard let id, id != boundMailbox else { clearAll(); return }
        try? FileManager.default.removeItem(at: MailboxPaths.file(Self.fileName, for: id))
    }

    /// Point at another mailbox's conversations.
    func rebind(to id: MailboxID) {
        guard id != boundMailbox else { return }
        // Only when it already belonged to a mailbox. Unbound means this is
        // the first binding after launch, and what is in memory came from
        // the old single-mailbox file -- writing it back would put an empty
        // copy where real data used to be.
        if boundMailbox != nil { persist() }
        boundMailbox = id
        fileURL = MailboxPaths.file(Self.fileName, for: id)
        conversations = []
        load()
    }

    private static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Maily", directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// Adds or replaces, keeps newest first, writes.
    func save(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.append(conversation)
        conversations.sort { $0.updatedAt > $1.updatedAt }
        persist()
        push(conversation)
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
        guard AppSettings.syncsChats else { return }
        Task.detached(priority: .background) { try? await Backend.delete("chats", id: id) }
    }

    func clearAll() {
        conversations = []
        try? FileManager.default.removeItem(at: fileURL)

        // What the phone forgets, the server forgets. Scoped to this mailbox
        // when there is one: an unqualified delete here meant removing one
        // account wiped every conversation the person had, on every device.
        let mailbox = boundMailbox
        Task.detached(priority: .background) {
            if let mailbox {
                try? await Backend.deleteAll("chats", mailbox: mailbox)
            } else {
                try? await Backend.deleteAll("chats")
            }
        }
    }

    // MARK: - Sync
    //
    // The local file stays the source of truth for what is on screen: the
    // chat has to open instantly and work on a plane. The server is a copy
    // that follows the account to another device. Writes go both ways as
    // they happen; reads happen once, when the app has a session.

    /// A conversation as the `chats` table holds it.
    private struct Row: Codable {
        var id: UUID
        var user_id: UUID
        /// Which mailbox it came out of. Nil for rows written before
        /// mailboxes had names.
        var mailbox_id: String?
        var title: String
        var turns: [ChatMessage]
        var created_at: Date
        var updated_at: Date
    }

    private func push(_ conversation: Conversation) {
        guard AppSettings.syncsChats else { return }
        let mailbox = boundMailbox?.rawValue
        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let row = Row(
                id: conversation.id,
                user_id: userID,
                mailbox_id: mailbox,
                title: conversation.title,
                turns: conversation.turns,
                created_at: conversation.createdAt,
                updated_at: conversation.updatedAt
            )
            try? await Backend.upsert("chats", [row])
        }
    }

    /// Brings down anything this phone has not seen. Newer wins on both
    /// sides, compared by `updatedAt`, so signing in on a second device adds
    /// its history rather than replacing it.
    func pull() async {
        guard AppSettings.syncsChats, await Backend.isSignedIn else { return }
        guard let rows: [Row] = try? await Backend.select(
            "chats", query: "select=*&order=updated_at.desc&limit=200"
        ) else { return }

        var merged = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            let incoming = Conversation(
                id: row.id, title: row.title,
                createdAt: row.created_at, updatedAt: row.updated_at, turns: row.turns
            )
            if let mine = merged[row.id], mine.updatedAt >= incoming.updatedAt { continue }
            merged[row.id] = incoming
        }

        conversations = merged.values.sorted { $0.updatedAt > $1.updatedAt }
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Conversation].self, from: data)
        else { return }
        conversations = stored.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // Losing history is a nuisance, not a failure worth surfacing
            // over the chat that is happening right now.
        }
    }
}
