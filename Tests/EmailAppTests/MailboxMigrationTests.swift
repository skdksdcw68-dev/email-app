import Testing
import Foundation
@testable import EmailApp

/// The one place in this feature where a silent bug costs somebody their mail.
///
/// It runs once, on a real mailbox, on a phone with no debugger attached, and
/// there is no second attempt. So the interesting cases here are not "does it
/// work" but "what is left behind when it stops halfway".
@MainActor
@Suite(.serialized)
struct MailboxMigrationTests {

    /// A container of its own: a temp folder for the files, a throwaway suite
    /// for the keys. Nothing here may touch the real ones.
    private struct Sandbox {
        let root: URL
        let support: URL
        let caches: URL
        let defaults: UserDefaults
        let suiteName: String

        init() {
            root = FileManager.default.temporaryDirectory
                .appending(path: "migration-\(UUID().uuidString)", directoryHint: .isDirectory)
            support = root.appending(path: "Support", directoryHint: .isDirectory)
            caches = root.appending(path: "Caches", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

            suiteName = "maily.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!

            MailboxPaths.supportOverride = support
            MailboxPaths.cachesOverride = caches
        }

        func tearDown() {
            MailboxPaths.supportOverride = nil
            MailboxPaths.cachesOverride = nil
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        /// The app as it was: one account, nine global keys, five files.
        func seedLegacyMailbox(address: String = "abel@example.com") {
            let account = """
            {"id":"\(UUID().uuidString)","email":"\(address)",\
            "displayName":"Abel Amare","connectedAt":0}
            """
            defaults.set(Data(account.utf8), forKey: "mail.account")

            defaults.set(true, forKey: "mail.hasImported")
            defaults.set(["m1", "m2"], forKey: "mail.readLocally")
            defaults.set(["m3"], forKey: "mail.repliedLocally")
            defaults.set("999", forKey: "mail.historyId")
            defaults.set(["m4": 4_000_000.0], forKey: "mail.snoozed")
            defaults.set(["t1": 5_000_000.0], forKey: "followups.dismissed")

            write("archive", to: support.appending(path: "mailbox.json"))
            let maily = support.appending(path: "Maily", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: maily, withIntermediateDirectories: true)
            for name in ["facts.json", "searches.json", "chats.json", "autoreply-queue.json"] {
                write(name, to: maily.appending(path: name))
            }

            let attachments = caches.appending(path: "Attachments", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
            write("pdf bytes", to: attachments.appending(path: "abc/report.pdf"))
        }

        func write(_ text: String, to url: URL) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? Data(text.utf8).write(to: url)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func read(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    // MARK: - The happy path

    @Test func itMovesTheOneMailboxIntoANamespace() {
        let box = Sandbox()
        defer { box.tearDown() }
        box.seedLegacyMailbox()

        let registry = MailboxRegistry(defaults: box.defaults)

        // The mailbox is now a record, and it is the active one.
        #expect(registry.accounts.count == 1)
        let account = try! #require(registry.active)
        #expect(account.address == "abel@example.com")
        #expect(account.provider == .gmail)
        #expect(account.displayName == "Abel Amare")

        // Read state, snoozes and the sync cursor all followed it.
        let suite = MailboxScope.defaults(for: account.id)
        #expect(suite.bool(forKey: "mail.hasImported"))
        #expect(suite.stringArray(forKey: "mail.readLocally") == ["m1", "m2"])
        #expect(suite.stringArray(forKey: "mail.repliedLocally") == ["m3"])
        #expect(suite.string(forKey: "mail.historyId") == "999")
        #expect((suite.dictionary(forKey: "mail.snoozed") as? [String: Double])?["m4"] == 4_000_000.0)
        #expect((suite.dictionary(forKey: "followups.dismissed") as? [String: Double])?["t1"] != nil)

        // The mail itself moved rather than being copied or lost.
        #expect(box.read(MailboxPaths.file("mailbox.json", for: account.id)) == "archive")
        #expect(!box.exists(box.support.appending(path: "mailbox.json")))
        for name in ["facts.json", "searches.json", "chats.json", "autoreply-queue.json"] {
            #expect(box.read(MailboxPaths.file(name, for: account.id)) == name)
        }

        // Attachments kept their folder structure, so nothing re-downloads.
        #expect(box.read(
            MailboxPaths.attachments(for: account.id).appending(path: "abc/report.pdf")
        ) == "pdf bytes")

        suite.removePersistentDomain(forName: MailboxScope.suiteName(for: account.id))
    }

    @Test func theGlobalsAreGoneAfterwards() {
        let box = Sandbox()
        defer { box.tearDown() }
        box.seedLegacyMailbox()

        let registry = MailboxRegistry(defaults: box.defaults)
        let id = registry.active!.id

        for key in MailboxMigration.scopedKeys {
            #expect(box.defaults.object(forKey: key) == nil, "\(key) was left behind")
        }
        #expect(box.defaults.data(forKey: "mail.account") == nil)
        #expect(box.defaults.integer(forKey: MailboxMigration.schemaKey) == MailboxMigration.schema)

        MailboxScope.defaults(for: id).removePersistentDomain(forName: MailboxScope.suiteName(for: id))
    }

    // MARK: - Running it twice

    @Test func runningItAgainChangesNothing() {
        let box = Sandbox()
        defer { box.tearDown() }
        box.seedLegacyMailbox()

        let first = MailboxRegistry(defaults: box.defaults)
        let id = first.active!.id

        // A second registry on the same defaults is what a second launch is.
        let second = MailboxRegistry(defaults: box.defaults)
        #expect(second.accounts.count == 1)
        #expect(second.active?.id == id)
        #expect(box.read(MailboxPaths.file("mailbox.json", for: id)) == "archive")

        MailboxScope.defaults(for: id).removePersistentDomain(forName: MailboxScope.suiteName(for: id))
    }

    @Test func theIdIsTheSameEveryTime() {
        // The whole reason it is derived rather than minted. The old id was a
        // fresh UUID on every launch, so nothing could be keyed on it.
        let first = MailboxID.derive(provider: .gmail, address: "abel@example.com")
        let second = MailboxID.derive(provider: .gmail, address: "ABEL@Example.com  ")
        #expect(first == second)

        // The same address at a different provider is a different mailbox.
        #expect(MailboxID.derive(provider: .imap, address: "abel@example.com") != first)
    }

    // MARK: - Nothing to do

    @Test func afreshInstallGetsAnEmptyRegistry() {
        let box = Sandbox()
        defer { box.tearDown() }

        let registry = MailboxRegistry(defaults: box.defaults)

        #expect(registry.accounts.isEmpty)
        #expect(registry.active == nil)
        // Marked done anyway, so it stops looking at ten keys every launch.
        #expect(box.defaults.integer(forKey: MailboxMigration.schemaKey) == MailboxMigration.schema)
    }

    @Test func anUnreadableAccountIsTreatedAsNoAccount() {
        // Better an empty registry and a connect screen than a crash on
        // launch with no way back.
        let box = Sandbox()
        defer { box.tearDown() }
        box.defaults.set(Data("not json".utf8), forKey: "mail.account")

        let registry = MailboxRegistry(defaults: box.defaults)
        #expect(registry.accounts.isEmpty)
    }

    // MARK: - Stopping halfway

    @Test func aCrashBeforeTheCommitLeavesEverythingRecoverable() {
        let box = Sandbox()
        defer { box.tearDown() }
        box.seedLegacyMailbox()

        // prepare() on its own is what happens if the app dies before the
        // registry is saved. Nothing destructive has run yet.
        let account = try! #require(MailboxMigration.prepare(defaults: box.defaults))

        #expect(box.defaults.data(forKey: "mail.account") != nil, "the account must survive")
        #expect(box.defaults.integer(forKey: MailboxMigration.schemaKey) < MailboxMigration.schema)

        // So the next launch picks it up and finishes.
        let registry = MailboxRegistry(defaults: box.defaults)
        #expect(registry.active?.id == account.id)
        #expect(box.read(MailboxPaths.file("mailbox.json", for: account.id)) == "archive")

        MailboxScope.defaults(for: account.id)
            .removePersistentDomain(forName: MailboxScope.suiteName(for: account.id))
    }

    @Test func afileAlreadyMovedIsNotMovedTwice() {
        let box = Sandbox()
        defer { box.tearDown() }
        box.seedLegacyMailbox()

        // An interrupted run: the archive is already at its destination, and
        // a stale copy is still at the source. The destination is the newer
        // truth and must win.
        let id = MailboxID.derive(provider: .gmail, address: "abel@example.com")
        box.write("already moved", to: MailboxPaths.file("mailbox.json", for: id))

        _ = MailboxRegistry(defaults: box.defaults)

        #expect(box.read(MailboxPaths.file("mailbox.json", for: id)) == "already moved")
        #expect(!box.exists(box.support.appending(path: "mailbox.json")))

        MailboxScope.defaults(for: id).removePersistentDomain(forName: MailboxScope.suiteName(for: id))
    }

    // MARK: - What must not move

    @Test func whatBelongsToThePersonStaysWhereItIs() {
        // A person is a person whichever inbox they write to, and how
        // somebody likes their mail written does not belong to one mailbox.
        // Moving these under an account loses them when it is removed.
        for key in ["people.important", "people.muted", "settings.appearance",
                    "ai.usage", "onboarding.completed", "bulkReply.consented"] {
            #expect(!MailboxMigration.scopedKeys.contains(key), "\(key) must not be scoped")
        }
    }
}
