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
enum MessageArchive {
    private static let filename = "mailbox.json"

    private static var url: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return directory.appendingPathComponent(filename)
    }

    /// Written off the main actor -- encoding a few thousand messages is not
    /// free, and this runs right after an import when the UI is still moving.
    static func save(_ messages: [Message]) async {
        guard let url else { return }
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

    static func load() async -> [Message] {
        guard let url else { return [] }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let messages = try? JSONDecoder().decode([Message].self, from: data)
            else { return [] }
            return messages
        }.value
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
