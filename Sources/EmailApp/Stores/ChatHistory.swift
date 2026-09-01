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
    private var disconnectObserver: NSObjectProtocol?

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
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        conversations = []
        try? FileManager.default.removeItem(at: fileURL)
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
