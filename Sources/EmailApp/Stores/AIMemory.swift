import Foundation
import Observation

/// What the assistant has been told to remember.
///
/// "I sign off as Abel." "Keep replies to three lines." "Yohannes is my
/// accountant." Small, stable facts a person should not have to repeat, and
/// the difference between an assistant that knows them and one that meets
/// them again every morning.
///
/// Kept on the phone and mirrored to the account, so they follow it to a new
/// device. Read on every question, which is why there is a cap: fifty facts
/// is more than anyone will set and still small enough to send whole.
@Observable
@MainActor
final class AIMemory {

    struct Fact: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var createdAt: Date = .now
    }

    /// Newest first.
    private(set) var facts: [Fact] = []

    static let limit = 50

    let fileURL: URL

    /// Deliberately not wired to `.mailboxDisconnected`, unlike chat history.
    /// These are facts about the person rather than their mail -- "keep
    /// replies short" outlives swapping inboxes. Signing out clears them.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        load()
    }

    private static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Maily", directoryHint: .isDirectory)
            .appending(path: "memory.json")
    }

    // MARK: - Changing

    /// Adds a fact, unless it is one already. Returns nil when it was a
    /// duplicate, so the caller can say so rather than claiming to have
    /// learned something twice.
    @discardableResult
    func remember(_ text: String) -> Fact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !facts.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }

        let fact = Fact(text: String(trimmed.prefix(280)))
        facts.insert(fact, at: 0)
        if facts.count > Self.limit { facts = Array(facts.prefix(Self.limit)) }
        persist()
        push(fact)
        return fact
    }

    func forget(_ id: UUID) {
        facts.removeAll { $0.id == id }
        persist()
        Task.detached(priority: .background) { try? await Backend.delete("memories", id: id) }
    }

    func forgetAll() {
        facts = []
        try? FileManager.default.removeItem(at: fileURL)
        Task.detached(priority: .background) { try? await Backend.deleteAll("memories") }
    }

    // MARK: - What the model is told

    /// The facts as one block for the prompt, oldest first so the newest
    /// correction reads as the last word.
    var prompt: String {
        guard !facts.isEmpty else { return "" }
        return facts.reversed().map { "- \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Sync

    private struct Row: Codable {
        var id: UUID
        var user_id: UUID
        var fact: String
        var created_at: Date
    }

    private func push(_ fact: Fact) {
        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let row = Row(id: fact.id, user_id: userID, fact: fact.text, created_at: fact.createdAt)
            try? await Backend.upsert("memories", [row])
        }
    }

    func pull() async {
        guard await Backend.isSignedIn else { return }
        guard let rows: [Row] = try? await Backend.select(
            "memories", query: "select=*&order=created_at.desc&limit=\(Self.limit)"
        ) else { return }

        var merged = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows where merged[row.id] == nil {
            merged[row.id] = Fact(id: row.id, text: row.fact, createdAt: row.created_at)
        }
        facts = merged.values
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.limit)
            .map { $0 }
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Fact].self, from: data)
        else { return }
        facts = stored.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(facts)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // Losing a preference is a nuisance, not a failure worth
            // interrupting the conversation over.
        }
    }
}
