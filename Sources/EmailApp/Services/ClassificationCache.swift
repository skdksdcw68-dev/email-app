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
        /// The person's own categories this landed in. Optional: written by
        /// builds that had none.
        let custom: [String]?
        /// What the model was told about the person's categories when this
        /// was decided, as id → revision. A category made or reworded since
        /// is one this entry has not heard of, and `CategoryStore.isStale`
        /// is how the message gets sorted again.
        let customSeen: [String: Int]?
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
        guard let data = MailboxScope.defaults.data(forKey: key),
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

    static func store(
        _ classification: AIService.Classification,
        for remoteID: String,
        seen: [String: Int] = [:]
    ) {
        var all = load()
        all[remoteID] = Entry(
            priority: classification.priority,
            needsReply: classification.needsReply,
            summary: classification.summary,
            category: classification.category,
            extract: classification.extract,
            custom: classification.custom,
            customSeen: seen.isEmpty ? nil : seen,
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
        MailboxScope.defaults.set(data, forKey: key)
    }

    static func clear() {
        entries = [:]
        isDirty = false
        MailboxScope.defaults.removeObject(forKey: key)
    }

    /// Drops what is held in memory without touching what was written, which
    /// is what a cold launch looks like -- and what changing the active
    /// mailbox has to look like too, since the entries belong to the mailbox
    /// they were read from.
    static func forgetInMemory() {
        entries = nil
        isDirty = false
    }

    // MARK: - Surviving a disconnect

    /// How long a removed mailbox's classifications wait for it to come back.
    ///
    /// Disconnecting wipes the mailbox's suite, and rightly: the entries are
    /// model-written summaries of mail somebody just asked to remove. But
    /// Abel disconnected and reconnected the same address within an hour and
    /// paid to have the whole import sorted again -- a thousand calls, half
    /// of a month's spend. So the entries are parked under the mailbox id for
    /// a week, put back if the same address returns, and deleted after that
    /// whether or not it did.
    static let parkedFor: TimeInterval = 7 * 24 * 60 * 60

    private static var parkingFolder: URL {
        let url = MailboxPaths.root.appending(path: "ParkedClassifications", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func parkingFile(for id: MailboxID) -> URL {
        parkingFolder.appending(path: "\(id.rawValue).json")
    }

    /// Before the suite is purged, while its entries can still be read.
    static func park(_ id: MailboxID) {
        flush()
        guard let data = MailboxScope.defaults(for: id).data(forKey: key) else { return }
        try? data.write(to: parkingFile(for: id), options: .atomic)
    }

    /// When a mailbox is activated. Restores what was parked within the week;
    /// the parked file goes either way.
    static func unpark(_ id: MailboxID) {
        let file = parkingFile(for: id)
        defer { try? FileManager.default.removeItem(at: file) }

        guard let modified = try? FileManager.default
                  .attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) < parkedFor,
              let data = try? Data(contentsOf: file)
        else { return }

        // Only where there is nothing already: a mailbox that has been
        // sorting since it came back has the newer answers.
        let suite = MailboxScope.defaults(for: id)
        guard suite.data(forKey: key) == nil else { return }
        suite.set(data, forKey: key)
    }

    /// Whatever has waited longer than a week is deleted, whoever it was for.
    static func sweepParked() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: parkingFolder, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  Date.now.timeIntervalSince(modified) >= parkedFor
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension AIService.Classification {
    init(_ entry: ClassificationCache.Entry) {
        self.init(
            priority: entry.priority,
            needsReply: entry.needsReply,
            summary: entry.summary,
            category: entry.category,
            extract: entry.extract,
            custom: entry.custom
        )
    }
}
