import Foundation
import Observation

/// What somebody has searched for, newest first.
///
/// Looking for the same thing twice is the normal case in email: the invoice
/// you could not find on Tuesday is the one you cannot find on Thursday. A
/// list of recent searches under an empty box turns the second attempt into
/// one tap.
///
/// Kept on the phone and mirrored to the account, the same way chats and
/// memory are. It holds what was typed, which can name people, so it goes
/// when the mailbox goes.
@Observable
@MainActor
final class SearchHistory {

    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        /// "mail" or "ai", so the row can show which kind it was and repeating
        /// it costs what it cost the first time.
        var mode: String = "mail"
        var results: Int = 0
        var createdAt: Date = .now
    }

    private(set) var entries: [Entry] = []

    /// Thirty is more than anybody scrolls and small enough to send whole.
    static let limit = 30

    /// Which mailbox these belong to. Nil when the store was handed an
    /// explicit file -- previews and tests -- and before any mailbox exists.
    private(set) var boundMailbox: MailboxID?
    /// A `var` because the active mailbox can change under it. Rebound, never
    /// reconstructed: this object is in the environment, and replacing it
    /// tears down every view holding it.
    private(set) var fileURL: URL

    private static let fileName = "searches.json"

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

    /// Point at another mailbox's searches.
    func rebind(to id: MailboxID) {
        guard id != boundMailbox else { return }
        // Only when it already belonged to a mailbox. Unbound means this is
        // the first binding after launch, and what is in memory came from
        // the old single-mailbox file -- writing it back would put an empty
        // copy where real data used to be.
        if boundMailbox != nil { persist() }
        boundMailbox = id
        fileURL = MailboxPaths.file(Self.fileName, for: id)
        // load() returns early when the file is not there, so without this a
        // brand-new mailbox would open showing the previous one's.
        entries = []
        load()
    }

    private static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Maily", directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    // MARK: - Recording

    /// Searching for the same thing again moves it to the top rather than
    /// adding a second row. A history with "invoice" in it four times is a
    /// log, not a shortcut.
    func record(_ text: String, mode: MailStore.SearchMode, results: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }

        entries.removeAll { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }
        let entry = Entry(
            text: String(trimmed.prefix(200)),
            mode: mode.rawValue,
            results: results
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries = Array(entries.prefix(Self.limit)) }

        persist()
        push(entry)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
        Task.detached(priority: .background) { try? await Backend.delete("searches", id: id) }
    }

    func clearAll() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)

        // Scoped to this mailbox when there is one. See the same note in
        // ChatHistory: an unqualified delete took everything, everywhere.
        let mailbox = boundMailbox
        Task.detached(priority: .background) {
            if let mailbox {
                try? await Backend.deleteAll("searches", mailbox: mailbox)
            } else {
                try? await Backend.deleteAll("searches")
            }
        }
    }

    // MARK: - Sync

    private struct Row: Codable {
        var id: UUID
        var user_id: UUID
        /// Which mailbox it was searched in. Nil for rows written before
        /// mailboxes had names.
        var mailbox_id: String?
        var text: String
        var mode: String
        var results: Int
        var created_at: Date
    }

    private func push(_ entry: Entry) {
        let mailbox = boundMailbox?.rawValue
        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let row = Row(
                id: entry.id, user_id: userID, mailbox_id: mailbox, text: entry.text,
                mode: entry.mode, results: entry.results, created_at: entry.createdAt
            )
            try? await Backend.upsert("searches", [row])
        }
    }

    func pull() async {
        guard await Backend.isSignedIn else { return }
        guard let rows: [Row] = try? await Backend.select(
            "searches", query: "select=*&order=created_at.desc&limit=\(Self.limit)"
        ) else { return }

        var merged = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows where merged[row.id] == nil {
            merged[row.id] = Entry(
                id: row.id, text: row.text, mode: row.mode,
                results: row.results, createdAt: row.created_at
            )
        }

        // Same text from two devices is still one search.
        var seen = Set<String>()
        entries = merged.values
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.text.lowercased()).inserted }
            .prefix(Self.limit)
            .map { $0 }
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = stored.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A lost history is a lost shortcut, not a failure worth
            // interrupting a search over.
        }
    }
}
