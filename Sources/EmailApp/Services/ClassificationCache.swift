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
        /// Added after the first release. Optional so entries written by the
        /// previous build still decode, instead of one failed key throwing
        /// away the whole cache on upgrade.
        let category: String?
        /// Whether a closer read was worth running. Optional like `category`,
        /// and for the same reason.
        let extract: Bool?
        let storedAt: Date
    }

    /// Held in memory, because this is asked about every message.
    ///
    /// It used to be read out of UserDefaults and JSON-decoded on every
    /// single call -- and the callers are loops over the whole mailbox, one
    /// of which runs twenty times a pass. On a few thousand messages that is
    /// tens of thousands of decodes of a five-hundred entry dictionary every
    /// time the app opens or refreshes, which is most of why opening it was
    /// slow and why it went slow again whenever mail came in.
    nonisolated(unsafe) private static var entries: [String: Entry]?
    /// Written but not yet saved. Saving is coalesced: encoding five hundred
    /// entries once per classified email was the same waste in reverse.
    nonisolated(unsafe) private static var isDirty = false

    static func load() -> [String: Entry] {
        if let entries { return entries }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            entries = [:]
            return [:]
        }
        entries = decoded
        return decoded
    }

    static func entry(for remoteID: String) -> Entry? {
        // Deliberately not `load()[remoteID]`: that hands back a copy of the
        // whole dictionary to read one value out of it.
        if entries == nil { _ = load() }
        return entries?[remoteID]
    }

    static func store(_ classification: AIService.Classification, for remoteID: String) {
        var all = load()
        all[remoteID] = Entry(
            priority: classification.priority,
            needsReply: classification.needsReply,
            summary: classification.summary,
            category: classification.category,
            extract: classification.extract,
            storedAt: .now
        )

        // Oldest out first once it is full.
        if all.count > capacity {
            let keep = all.sorted { $0.value.storedAt > $1.value.storedAt }.prefix(capacity)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }

        entries = all
        isDirty = true
    }

    /// Writes what has been stored since the last call, if anything.
    ///
    /// Called after each batch of classifications rather than after each
    /// message, and again when the app goes to the background. Losing a
    /// batch to a kill costs a re-classification, which is the thing this
    /// cache exists to avoid -- so it is flushed often, just not per message.
    static func flush() {
        guard isDirty, let entries else { return }
        isDirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        entries = [:]
        isDirty = false
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Drops what is held in memory without touching what was written, which
    /// is what a cold launch looks like. Only the tests need it; the app
    /// gets this for free by starting.
    static func forgetInMemory() {
        entries = nil
        isDirty = false
    }
}

extension AIService.Classification {
    init(_ entry: ClassificationCache.Entry) {
        self.init(
            priority: entry.priority,
            needsReply: entry.needsReply,
            summary: entry.summary,
            category: entry.category,
            extract: entry.extract
        )
    }
}
