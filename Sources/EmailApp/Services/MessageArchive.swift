import Foundation

/// The mailbox on disk, so a cold launch shows mail instantly and an aeroplane
/// still shows something.
///
/// Deliberately not UserDefaults: that is a plist read whole into memory on
/// first touch, and a few thousand emails there would slow every launch of the
/// app, not just this feature.
///
/// HTML bodies are dropped before writing. They are the overwhelming bulk of
/// a message -- 20 to 80KB each against 2 to 5KB for everything else -- so
/// keeping them would turn a 5MB archive into 100MB and a fast launch into a
/// slow one. Offline reading is therefore plain text; opening a message with
/// a connection fetches the real HTML. That is a deliberate trade, and the
/// reading view already falls back cleanly when htmlBody is nil.
/// A mailbox each. Every function names the one it means -- there is no
/// "current archive", because a background catch-up for a mailbox that is not
/// in front of you writes here too, and it must not be able to reach the
/// wrong file by forgetting to say which.
enum MessageArchive {
    static let filename = "mailbox.json"

    /// Where the single mailbox used to live, before there could be two. Read
    /// only by the migration, which moves it.
    static var legacyURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return directory.appendingPathComponent(filename)
    }

    private static func url(for mailbox: MailboxID) -> URL {
        MailboxPaths.file(filename, for: mailbox)
    }

    /// Written off the main actor -- encoding a few thousand messages is not
    /// free, and this runs right after an import when the UI is still moving.
    static func save(_ messages: [Message], mailbox: MailboxID) async {
        let url = url(for: mailbox)
        let stripped = messages.map { message -> Message in
            var copy = message
            copy.htmlBody = nil
            return copy
        }

        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(stripped) else { return }
            // Atomic, so a crash mid-write cannot leave a half-written file
            // that fails to decode on the next launch.
            try? data.write(to: url, options: .atomic)
        }.value
    }

    static func load(mailbox: MailboxID) async -> [Message] {
        let url = url(for: mailbox)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let messages = try? JSONDecoder().decode([Message].self, from: data)
            else { return [] }
            return messages
        }.value
    }

    static func clear(mailbox: MailboxID) {
        try? FileManager.default.removeItem(at: url(for: mailbox))
    }
}

extension MessageArchive {
    /// How much room one mailbox's offline copy takes, for the storage screen
    /// and the per-account page.
    static func formattedSize(mailbox: MailboxID) async -> String {
        let path = url(for: mailbox).path

        return await Task.detached(priority: .utility) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }.value
    }
}
