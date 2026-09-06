import Foundation
import Observation

/// Every mailbox the app knows about, and which one is in front of you.
///
/// Separate from `MailStore` on purpose. `MailStore` holds *a* mailbox's mail
/// and swaps its contents when the active one changes; this holds the list,
/// and it outlives every swap. Screens that show accounts read this and never
/// touch the mail.
@Observable
@MainActor
final class MailboxRegistry {

    /// Which mailbox opens when the app does.
    enum DefaultPolicy: Codable, Hashable {
        /// Whichever was last in front of you. Right for most people.
        case lastUsed
        /// Always this one, whatever you were doing yesterday.
        case fixed(MailboxID)
    }

    /// In display order, which the person can change. Not sorted by date --
    /// a list that reorders itself when you use it is a list you cannot learn.
    private(set) var accounts: [MailAccount] = []
    private(set) var activeID: MailboxID?
    private(set) var defaultPolicy: DefaultPolicy = .lastUsed

    private let defaults: UserDefaults
    private static let key = "mailbox.registry"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        migrateIfNeeded()
    }

    /// Takes on the single mailbox the app used to have.
    ///
    /// Here rather than at the app's entry point because *this* is the first
    /// thing that reads the new layout, and a migration that runs after the
    /// first read is a migration that ran too late. It is a no-op on every
    /// launch after the first, and on every fresh install.
    private func migrateIfNeeded() {
        guard let migrated = MailboxMigration.prepare(defaults: defaults) else { return }

        // Commit before cleaning up. If the app dies between these two, the
        // registry has the mailbox and the old keys are still there --
        // duplicated, which is harmless. The other order loses them.
        upsert(migrated)
        setActive(migrated.id)
        MailboxMigration.finish(defaults: defaults)
    }

    // MARK: - Reading

    var active: MailAccount? { activeID.flatMap(account) }
    var isEmpty: Bool { accounts.isEmpty }
    var hasSeveral: Bool { accounts.count > 1 }

    func account(_ id: MailboxID) -> MailAccount? {
        accounts.first { $0.id == id }
    }

    /// The push path. A silent push carries an address and needs a mailbox,
    /// and this is the whole lookup -- no table to keep in step, because the
    /// id is derived from the address.
    func account(forAddress address: String) -> MailAccount? {
        let wanted = MailboxID.canonical(address)
        return accounts.first { $0.address == wanted }
    }

    /// Whether this address is already connected. The add flow asks before
    /// starting, so signing in as somebody already present says so rather
    /// than quietly doing nothing.
    func holds(_ address: String) -> Bool {
        account(forAddress: address) != nil
    }

    /// Which to open on a cold launch.
    var opening: MailAccount? {
        switch defaultPolicy {
        case .fixed(let id):
            // Falls through to last-used if that mailbox was removed, rather
            // than opening on nothing.
            return account(id) ?? lastUsed
        case .lastUsed:
            return lastUsed
        }
    }

    private var lastUsed: MailAccount? {
        accounts.max { $0.lastActiveAt < $1.lastActiveAt } ?? accounts.first
    }

    /// A colour nothing is wearing yet.
    var nextTint: MailboxTint {
        MailboxTint.next(after: accounts.map(\.tint))
    }

    // MARK: - Writing

    /// Adds it, or updates the one already there.
    ///
    /// Never re-mints. `restore()` used to build a whole new account object
    /// every launch, which is how the old id managed to change on every cold
    /// start; the id is derived now, but the rule stands -- what comes back
    /// from a provider updates a record, it does not replace one.
    func upsert(_ account: MailAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        save()
    }

    /// Changes one field without the caller having to rebuild the record.
    func update(_ id: MailboxID, _ change: (inout MailAccount) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
        save()
    }

    func setActive(_ id: MailboxID) {
        guard account(id) != nil else { return }
        activeID = id
        update(id) { $0.lastActiveAt = .now }
        save()
    }

    func setDefaultPolicy(_ policy: DefaultPolicy) {
        defaultPolicy = policy
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Forgets a mailbox: the record, its credentials, its `UserDefaults`
    /// suite and its files.
    ///
    /// What it deliberately does *not* do is any provider teardown --
    /// stopping the Gmail watch and revoking the grant belong to whoever owns
    /// the token, and they have to happen before this, because revoking first
    /// makes stopping impossible.
    func forget(_ id: MailboxID) {
        accounts.removeAll { $0.id == id }
        Keychain.deleteAll(for: id)
        // Before the purge, while the suite can still be read. Kept a week
        // in case the same address comes straight back, which is the one
        // case where wiping it costs real money: the whole import, sorted
        // again.
        ClassificationCache.park(id)
        MailboxScope.purge(id)
        MailboxPaths.purge(id)
        // Their face goes with the rest of it. Signing out is meant to leave
        // nothing of a mailbox on the phone, and a photograph of its owner
        // sitting in Application Support is not nothing.
        AvatarStore.shared.forget(key: id.rawValue)

        if activeID == id { activeID = accounts.first?.id }
        if case .fixed(let pinned) = defaultPolicy, pinned == id {
            defaultPolicy = .lastUsed
        }
        save()

        // Anything holding data for this mailbox drops it. The id in the
        // payload is what tells five stores whether this was them.
        NotificationCenter.default.post(
            name: .mailboxDisconnected,
            object: nil,
            userInfo: [MailboxNotice.key: id.rawValue]
        )
    }

    /// A registry nothing else shares.
    ///
    /// Previews and tests need one, and they need a *fresh* one: a suite they
    /// all wrote into would accumulate mailboxes across a run, so a test that
    /// disconnects the only account would find one left over from another
    /// test and carry on as if nothing had happened. That is the kind of
    /// failure that reads as a product bug.
    static func throwaway() -> MailboxRegistry {
        let suite = UserDefaults(suiteName: "maily.throwaway.\(UUID().uuidString)")
        return MailboxRegistry(defaults: suite ?? .standard)
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var accounts: [MailAccount]
        var activeID: MailboxID?
        var defaultPolicy: DefaultPolicy
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        accounts = stored.accounts
        activeID = stored.activeID
        defaultPolicy = stored.defaultPolicy
    }

    private func save() {
        let stored = Stored(accounts: accounts, activeID: activeID, defaultPolicy: defaultPolicy)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
