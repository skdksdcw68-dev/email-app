import Foundation

/// Moves the one mailbox this app has always had into a namespace of its own.
///
/// Every key and every file was a bare global name, which is right for one
/// mailbox and destructive for two. This runs once, before anything reads the
/// archive, and puts the existing mailbox where the new code expects it.
///
/// **The order is the whole design.** Copy, then move, then commit, then
/// clean:
///
///   - A crash before the commit leaves every original in place and the flag
///     unset, so the next launch runs it again from the top.
///   - A crash after the commit leaves stale keys in `.standard`, which
///     nothing reads and which cost a few kilobytes.
///
/// At no point is the only copy of anything in flight. That matters more than
/// it usually would: this runs on somebody's real mailbox, on a device with
/// no debugger attached, and there is no second attempt at getting it right.
enum MailboxMigration {

    /// Bumped when the layout changes. 2 is "namespaced by mailbox".
    static let schema = 2
    static let schemaKey = "mailbox.schema"

    /// The single mailbox, as it was stored before this existed.
    private static let legacyAccountKey = "mail.account"

    /// Everything that belongs to one mailbox rather than to the person.
    ///
    /// Deliberately *not* here: `people.*` (a person is a person whichever
    /// inbox they write to), `settings.*`, `ai.usage`, `bulkReply.consented`
    /// and `onboarding.*`. Those describe the human, and moving them under a
    /// mailbox would lose them the moment that mailbox was removed.
    static let scopedKeys = [
        "mail.hasImported",
        "mail.lastVerifiedAt",
        "mail.readLocally",
        "mail.repliedLocally",
        "mail.historyId",
        "mail.importLedger",
        "mail.snoozed",
        "ai.classifications",
        "followups.dismissed",
    ]

    /// What the old `GmailAccount` looked like. Kept here rather than reading
    /// the live type, so a later change to `MailAccount` cannot quietly break
    /// the ability to read what is already on somebody's phone.
    private struct LegacyAccount: Decodable {
        var email: String
        var displayName: String
        var connectedAt: Date
    }

    // MARK: - Running it

    /// Copies the keys and moves the files, and hands back the mailbox they
    /// now belong to.
    ///
    /// Deliberately does not write the registry, and deliberately does not
    /// mark itself done. The registry is what calls this -- from its own
    /// `init`, before anything can read a stale layout -- so it commits
    /// itself and then calls `finish`. Splitting it that way is also what
    /// keeps the ordering honest: everything here can be repeated safely,
    /// and nothing here is destructive.
    ///
    /// Returns nil when there is nothing to do, which is every launch after
    /// the first and every fresh install.
    static func prepare(defaults: UserDefaults = .standard) -> MailAccount? {
        guard defaults.integer(forKey: schemaKey) < schema else { return nil }

        // A fresh install. Nothing to move, and marking it done stops this
        // looking at every key on every launch for the life of the app.
        guard let data = defaults.data(forKey: legacyAccountKey),
              let legacy = try? JSONDecoder().decode(LegacyAccount.self, from: data)
        else {
            defaults.set(schema, forKey: schemaKey)
            return nil
        }

        let account = MailAccount(
            provider: .gmail,
            address: legacy.email,
            displayName: legacy.displayName,
            tint: .blue,
            connectedAt: legacy.connectedAt,
            lastActiveAt: .now
        )

        copyKeys(from: defaults, to: MailboxScope.defaults(for: account.id))
        moveFiles(for: account.id)
        return account
    }

    /// Called once the registry holding the migrated mailbox has been saved.
    ///
    /// This is the only destructive step, and it is last for that reason. A
    /// crash before it leaves every original in place and the flag unset, so
    /// the next launch starts again from the top; a crash after it leaves
    /// nothing but a few stale kilobytes nothing reads.
    static func finish(defaults: UserDefaults = .standard) {
        defaults.set(schema, forKey: schemaKey)
        for key in scopedKeys { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: legacyAccountKey)
    }

    // MARK: - The steps

    private static func copyKeys(from source: UserDefaults, to destination: UserDefaults) {
        for key in scopedKeys {
            guard let value = source.object(forKey: key) else { continue }
            destination.set(value, forKey: key)
        }
    }

    /// Renames rather than rewrites. `mailbox.json` can be several megabytes
    /// and `moveItem` does not care -- it is a directory entry change, not a
    /// copy, so there is no window where the file is half-somewhere.
    private static func moveFiles(for id: MailboxID) {
        move(MailboxPaths.legacyArchive,
             to: MailboxPaths.file(MessageArchive.filename, for: id))

        for name in ["facts.json", "searches.json", "chats.json", "autoreply-queue.json"] {
            move(MailboxPaths.legacyFile(name), to: MailboxPaths.file(name, for: id))
        }

        moveAttachments(for: id)
    }

    /// Attachments were one flat folder for the one mailbox. It becomes that
    /// mailbox's folder, so nothing has to be downloaded again.
    ///
    /// Two steps rather than one, because the destination is *inside* the
    /// source -- `Attachments` becoming `Attachments/<id>` -- and moving a
    /// directory into itself is not a thing. So it goes aside first.
    private static func moveAttachments(for id: MailboxID) {
        let manager = FileManager.default
        let old = MailboxPaths.legacyAttachments
        let new = MailboxPaths.attachments(for: id)

        guard manager.fileExists(atPath: old.path),
              !manager.fileExists(atPath: new.path)
        else { return }

        let staging = MailboxPaths.cachesBase
            .appending(path: "Attachments-moving", directoryHint: .isDirectory)
        try? manager.removeItem(at: staging)
        guard (try? manager.moveItem(at: old, to: staging)) != nil else { return }

        try? manager.createDirectory(at: old, withIntermediateDirectories: true)
        try? manager.moveItem(at: staging, to: new)
    }

    /// Idempotent: a destination that already exists with no source left is
    /// this step having run before, not a failure.
    private static func move(_ source: URL, to destination: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        guard !manager.fileExists(atPath: destination.path) else {
            // Both present means an interrupted run wrote the destination and
            // did not get to delete the source. The destination is the newer
            // truth; drop the leftover.
            try? manager.removeItem(at: source)
            return
        }
        try? manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? manager.moveItem(at: source, to: destination)
    }
}

