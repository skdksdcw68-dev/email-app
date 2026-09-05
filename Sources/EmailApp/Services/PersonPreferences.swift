import Foundation

/// What the user has said about a person, which always beats what Maily
/// worked out on its own.
///
/// This is the whole of "AI learning" in Maily, and deliberately so: no
/// opaque model of your habits, just corrections that stick and visibly change
/// priority. Mark someone important and their mail scores higher. Mute them
/// and it never reads as urgent. Recategorise them and it stays that way.
///
/// **Per mailbox**, and that is a decision rather than an accident. The same
/// human is a different relationship at each address: an accountant who
/// matters enormously in a work inbox is nobody in a personal one, and a
/// newsletter muted at home may be the one thing worth reading at work.
/// Account-wide stars would make one of those two mailboxes wrong.
///
/// 🔴 Which means every cache below has to be dropped when the mailbox
/// changes -- see `resetCache()` and its call in `MailboxScope.activate`.
enum PersonPreferences {
    private static let importantKey = "people.important"
    private static let mutedKey = "people.muted"
    private static let categoryKey = "people.categories"

    // MARK: - Important

    // Every one of these is read per person while the People tab is being
    // assembled -- and that assembly walks the whole mailbox. Reading them
    // out of UserDefaults each time meant hundreds of fetches and hundreds of
    // fresh Sets per draw, and again on every keystroke in the search field.
    // Held in memory and written through instead.
    //
    // Behind a lock, and it is not optional. These caches fill themselves on
    // *read*, and the reads come from two places at once: the main thread
    // building `MailboxIndex`, and twenty-five background tasks parsing a
    // page of Gmail, where `MessageClassifier` asks whether each sender is
    // important or muted. Installing a `Set` buffer from twenty-six threads
    // is the same heap corruption that killed `AIUsage`, waiting to be found.
    private static let importantCache = Guarded<Set<String>?>(nil)
    private static let mutedCache = Guarded<Set<String>?>(nil)
    private static let overridesCache = Guarded<[String: String]?>(nil)
    private static let relationshipsCache = Guarded<[String: String]?>(nil)

    /// Fill-on-read, with the reading done *outside* the lock.
    ///
    /// This is the whole trick and getting it wrong hangs the app. The lock
    /// is an unfair lock: a waiter spins rather than sleeping, and a spinning
    /// thread on Swift's cooperative pool cannot yield to run anything else.
    /// The pool has about as many threads as the phone has cores. So holding
    /// this across a `UserDefaults` read, while twenty-five Gmail parse tasks
    /// queue behind it, starves the pool and the import simply stops.
    ///
    /// Under contention `load()` may run more than once. That is fine -- it
    /// is a read with no side effects, and paying for it twice is far cheaper
    /// than the alternative.
    private static func cached<Value>(
        _ store: Guarded<Value?>,
        load: () -> Value
    ) -> Value {
        if let held = store.read({ $0 }) { return held }

        let loaded = load()

        return store.withLock { held in
            // Somebody else may have filled it while this was reading. Theirs
            // is as good as ours, and using it keeps every caller agreeing.
            if let held { return held }
            held = loaded
            return loaded
        }
    }

    static var important: Set<String> {
        get {
            cached(importantCache) {
                Set(MailboxScope.defaults.stringArray(forKey: importantKey) ?? [])
            }
        }
        set {
            importantCache.withLock { held in held = newValue }
            MailboxScope.defaults.set(Array(newValue), forKey: importantKey)
        }
    }

    static func isImportant(_ address: String) -> Bool {
        important.contains(address.lowercased())
    }

    static func setImportant(_ isImportant: Bool, for address: String) {
        var all = important
        let key = address.lowercased()
        if isImportant {
            all.insert(key)
            // The two are opposites; being both would make scoring incoherent.
            setMuted(false, for: address)
        } else {
            all.remove(key)
        }
        important = all
        SettingsSync.notify(.people)
    }

    // MARK: - Muted

    static var muted: Set<String> {
        get {
            cached(mutedCache) {
                Set(MailboxScope.defaults.stringArray(forKey: mutedKey) ?? [])
            }
        }
        set {
            mutedCache.withLock { held in held = newValue }
            MailboxScope.defaults.set(Array(newValue), forKey: mutedKey)
        }
    }

    static func isMuted(_ address: String) -> Bool {
        muted.contains(address.lowercased())
    }

    static func setMuted(_ isMuted: Bool, for address: String) {
        var all = muted
        let key = address.lowercased()
        if isMuted {
            all.insert(key)
        } else {
            all.remove(key)
        }
        muted = all
        SettingsSync.notify(.people)
    }

    // MARK: - Category

    private static var overrides: [String: String] {
        get {
            cached(overridesCache) {
                MailboxScope.defaults.dictionary(forKey: categoryKey) as? [String: String] ?? [:]
            }
        }
        set {
            overridesCache.withLock { held in held = newValue }
            MailboxScope.defaults.set(newValue, forKey: categoryKey)
        }
    }

    static func category(for address: String) -> PersonCategory? {
        overrides[address.lowercased()].flatMap(PersonCategory.init(rawValue:))
    }

    static func setCategory(_ category: PersonCategory?, for address: String) {
        var all = overrides
        let key = address.lowercased()
        if let category {
            all[key] = category.rawValue
        } else {
            all.removeValue(forKey: key)
        }
        overrides = all
    }

    // MARK: - Relationship in the user's own words

    /// "Freelancer", "Landlord", "Book club": a relationship the four
    /// inferred categories cannot name. Shown in place of the category
    /// wherever the person appears, and offered as its own filter.
    private static let relationshipKey = "people.relationships"

    private static var relationships: [String: String] {
        get {
            cached(relationshipsCache) {
                MailboxScope.defaults.dictionary(forKey: relationshipKey) as? [String: String] ?? [:]
            }
        }
        set {
            relationshipsCache.withLock { held in held = newValue }
            MailboxScope.defaults.set(newValue, forKey: relationshipKey)
        }
    }

    static func relationshipName(for address: String) -> String? {
        relationships[address.lowercased()]
    }

    static func setRelationshipName(_ name: String?, for address: String) {
        var all = relationships
        let key = address.lowercased()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            all.removeValue(forKey: key)
        } else {
            all[key] = trimmed
        }
        relationships = all
    }

    /// How much a person's own standing shifts the priority of their mail.
    ///
    /// Weight, not a verdict. Marking someone important must not make every
    /// message from them urgent -- that would be a rule, not a judgement, and
    /// it would make the loudest tag meaningless within a week.
    static func scoreAdjustment(for address: String) -> Int {
        if isImportant(address) { return 15 }
        if isMuted(address) { return -25 }
        return 0
    }

    /// Drops every in-memory copy, so the next read comes from whichever
    /// mailbox is now active.
    ///
    /// Called by `MailboxScope.activate`, alongside the other scoped caches.
    /// Nothing else should call it: these fill on read, so clearing them at
    /// any other moment only costs a re-read.
    static func resetCache() {
        importantCache.withLock { $0 = nil }
        mutedCache.withLock { $0 = nil }
        overridesCache.withLock { $0 = nil }
        relationshipsCache.withLock { $0 = nil }
    }

    /// Adds what another device has marked, without removing anything.
    ///
    /// Union rather than replace: there is no case where a phone *means* to
    /// unmark somebody by not mentioning them -- it has only not heard about
    /// them yet. See the note in `SettingsSync.apply`, including what this
    /// costs: un-starring does not propagate until there are tombstones.
    static func merge(important incoming: Set<String>) {
        // Through `setImportant` rather than writing the set directly, so the
        // rule that somebody cannot be both important and muted is enforced
        // here too. Writing the arrays by hand would have been three lines
        // shorter and would have let a sync produce a state the app itself
        // cannot.
        for address in incoming where !important.contains(address.lowercased()) {
            setImportant(true, for: address)
        }
    }

    static func merge(muted incoming: Set<String>) {
        for address in incoming where !muted.contains(address.lowercased()) {
            // Something marked important here wins over something muted
            // elsewhere: the stronger signal is the one somebody chose most
            // recently on the device they are holding.
            guard !important.contains(address.lowercased()) else { continue }
            setMuted(true, for: address)
        }
    }

    static func clearAll() {
        importantCache.withLock { held in held = [] }
        mutedCache.withLock { held in held = [] }
        overridesCache.withLock { held in held = [:] }
        relationshipsCache.withLock { held in held = [:] }
        MailboxScope.defaults.removeObject(forKey: importantKey)
        MailboxScope.defaults.removeObject(forKey: mutedKey)
        MailboxScope.defaults.removeObject(forKey: categoryKey)
        MailboxScope.defaults.removeObject(forKey: relationshipKey)
    }
}
