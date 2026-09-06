import Foundation

/// Where the active mailbox keeps its things.
///
/// Every stored thing in the app was a bare global name -- `mail.readLocally`,
/// `mailbox.json` -- which is exactly right for one mailbox and silently
/// destructive for two: the second one writes over the first's read state,
/// snoozes, classifications and archive, and there is no way to tell
/// afterwards which mailbox any of it belonged to.
///
/// **A suite per mailbox, not a prefix per key.** The prefix version means
/// rewriting every key string and hoping none was missed; this version means
/// call sites change `UserDefaults.standard` to `MailboxScope.defaults` and
/// nothing else. It also makes removing a mailbox one call --
/// `removePersistentDomain` -- with no possibility of leaving a key behind.
/// `UserStore` already proves the pattern works here with its previews suite.
///
/// Not `@MainActor`, and deliberately: the stores that read it
/// (`SnoozeStore`, `ClassificationCache`, `FollowUpPreferences`,
/// `ImportLedger`) are enums of `nonisolated(unsafe)` statics, and isolating
/// this would put an actor hop inside a list row's read. That makes the
/// pointer process-global mutable state, so there is one rule and it is not
/// optional: **only the main actor moves it, and background work for a
/// mailbox that is not the active one never touches a scoped store.** That
/// work uses the backend directly and writes to paths it names itself.
enum MailboxScope {

    /// Which mailbox the scoped stores are currently pointed at. Nil before
    /// anything is connected, and during the migration.
    nonisolated(unsafe) private(set) static var current: MailboxID?

    /// What the scoped stores read and write.
    ///
    /// Falls back to `.standard` when nothing is active, so a store touched
    /// before a mailbox exists still works rather than crashing. Nothing
    /// meaningful is written in that window.
    nonisolated(unsafe) private(set) static var defaults: UserDefaults = .standard

    static func suiteName(for id: MailboxID) -> String { "maily.mailbox.\(id.rawValue)" }

    /// Points everything scoped at a different mailbox.
    ///
    /// The flush before the swap matters: `ClassificationCache` batches its
    /// writes, so anything unwritten belongs to the mailbox being left and
    /// would otherwise be saved into the one being joined.
    @MainActor
    static func activate(_ id: MailboxID) {
        guard id != current else { return }

        ClassificationCache.flush()

        // A mailbox that was disconnected this week gets its sorting back
        // before anything reads the suite, so nothing is paid for twice.
        ClassificationCache.unpark(id)
        ClassificationCache.sweepParked()

        defaults = UserDefaults(suiteName: suiteName(for: id)) ?? .standard
        current = id

        // These are all in-memory copies of what was just swapped out from
        // under them. Left alone they would answer questions about the
        // previous mailbox using the previous mailbox's data, under the new
        // mailbox's name.
        SnoozeStore.resetCache()
        ClassificationCache.forgetInMemory()
        FollowUpPreferences.resetCache()
        SemanticIndex.forgetEverything()
        // 🔴 Joined this list when important and muted senders became
        // per-mailbox. Its caches fill on read and are static, so without
        // this the People tab would score the new mailbox's senders against
        // the previous mailbox's stars -- silently, and looking entirely
        // normal.
        PersonPreferences.resetCache()
        // The categories belong to the mailbox they were read from too.
        CategoryStore.shared.reload()
    }

    /// Forgets everything one mailbox stored in `UserDefaults`. One call, and
    /// no key can be missed.
    @MainActor
    static func purge(_ id: MailboxID) {
        let name = suiteName(for: id)
        UserDefaults.standard.removePersistentDomain(forName: name)
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        if current == id {
            current = nil
            defaults = .standard
        }
    }

    /// Used only by the migration and by tests, which need to write into a
    /// suite without making it the active one.
    static func defaults(for id: MailboxID) -> UserDefaults {
        UserDefaults(suiteName: suiteName(for: id)) ?? .standard
    }
}

/// Where the active mailbox keeps its files.
///
/// The archive, the facts, the chats and the searches are all read out of one
/// specific mailbox, so they live under it. Assistant memory does not -- what
/// somebody asked Maily to remember about how they write is about them, not
/// about a mailbox, and it stays where it is.
enum MailboxPaths {

    /// Pointed somewhere else by the migration tests, which have to run the
    /// whole move against a temporary folder rather than the real container.
    /// Nil everywhere else, which is every path the app itself takes.
    nonisolated(unsafe) static var supportOverride: URL?
    nonisolated(unsafe) static var cachesOverride: URL?

    // `.first`, not `[0]`. The array is never empty on iOS, but a subscript
    // that traps is a crash on launch with nothing to read afterwards, and
    // the fallback costs one line.
    static var supportBase: URL {
        supportOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var cachesBase: URL {
        cachesOverride
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// `<Application Support>/Maily`
    static var root: URL {
        supportBase.appending(path: "Maily", directoryHint: .isDirectory)
    }

    // MARK: - Where the one mailbox used to live
    //
    // Read only by the migration, which moves them under an id and then
    // never looks again.

    /// The archive was the odd one out -- it was never under `Maily/`.
    static var legacyArchive: URL {
        supportBase.appending(path: MessageArchive.filename)
    }

    static func legacyFile(_ name: String) -> URL {
        root.appending(path: name)
    }

    static var legacyAttachments: URL {
        cachesBase.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    /// `<Application Support>/Maily/Mailboxes/<id>`, created if it is not there.
    static func directory(for id: MailboxID) -> URL {
        let url = root
            .appending(path: "Mailboxes", directoryHint: .isDirectory)
            .appending(path: id.rawValue, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ name: String, for id: MailboxID) -> URL {
        directory(for: id).appending(path: name)
    }

    /// `<Caches>/Attachments/<id>`. Caches rather than Application Support
    /// because these are re-downloadable, which is also why they are not
    /// backed up.
    static func attachments(for id: MailboxID) -> URL {
        legacyAttachments.appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    /// Everything one mailbox holds on disk, gone.
    static func purge(_ id: MailboxID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        try? FileManager.default.removeItem(at: attachments(for: id))
    }
}
