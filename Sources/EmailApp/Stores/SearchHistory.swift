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

    let fileURL: URL
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
            .appending(path: "searches.json")
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
        Task.detached(priority: .background) { try? await Backend.deleteAll("searches") }
    }

    // MARK: - Sync

    private struct Row: Codable {
        var id: UUID
        var user_id: UUID
        var text: String
        var mode: String
        var results: Int
        var created_at: Date
    }

    private func push(_ entry: Entry) {
        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let row = Row(
                id: entry.id, user_id: userID, text: entry.text,
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
