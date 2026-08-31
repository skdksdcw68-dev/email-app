import Foundation

/// Remembers what the model decided about a message, keyed by Gmail's own id.
///
/// Two things this fixes. Refreshing replaces the whole message array, so
/// without a cache every pull-to-refresh threw away the AI tags and paid to
/// derive them again. And a message that has been classified once does not
/// change, so classifying it twice is pure waste.
enum ClassificationCache {
    private static let key = "ai.classifications"
    /// Enough for a long scrollback without letting the store grow forever.
    private static let capacity = 500

    struct Entry: Codable {
        let priority: String
        let needsReply: Bool
        let summary: String
        let storedAt: Date
    }

    static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    static func entry(for remoteID: String) -> Entry? {
        load()[remoteID]
    }

    static func store(_ classification: AIService.Classification, for remoteID: String) {
        var all = load()
        all[remoteID] = Entry(
            priority: classification.priority,
            needsReply: classification.needsReply,
            summary: classification.summary,
            storedAt: .now
        )

        // Oldest out first once it is full.
        if all.count > capacity {
            let keep = all.sorted { $0.value.storedAt > $1.value.storedAt }.prefix(capacity)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }

        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

extension AIService.Classification {
    init(_ entry: ClassificationCache.Entry) {
        self.init(priority: entry.priority, needsReply: entry.needsReply, summary: entry.summary)
    }
}
