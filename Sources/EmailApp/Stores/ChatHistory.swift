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
    /// Posted when the mailbox is disconnected. Anything that keeps mail
    /// content on disk clears itself on this.
    static let mailboxDisconnected = Notification.Name("maily.mailboxDisconnected")
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

    let fileURL: URL
    /// Read in `deinit`, which is not on the main actor. The token is only
    /// ever written once, in `init`, so there is nothing to race.
    nonisolated(unsafe) private var disconnectObserver: NSObjectProtocol?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        load()

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .mailboxDisconnected, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearAll() }
        }
    }

    deinit {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    private static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Maily", directoryHint: .isDirectory)
            .appending(path: "chats.json")
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
        // What the phone forgets, the server forgets. Disconnecting a mailbox
        // has always wiped the local file; leaving the synced copy behind
        // would make that promise a lie.
        Task.detached(priority: .background) { try? await Backend.deleteAll("chats") }
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
        var title: String
        var turns: [ChatMessage]
        var created_at: Date
        var updated_at: Date
    }

    private func push(_ conversation: Conversation) {
        guard AppSettings.syncsChats else { return }
        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let row = Row(
                id: conversation.id,
                user_id: userID,
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
