import Foundation

/// What the user has said about a person, which always beats what Maily
/// worked out on its own.
///
/// This is the whole of "AI learning" in Maily, and deliberately so: no
/// opaque model of your habits, just corrections that stick and visibly change
/// priority. Mark someone important and their mail scores higher. Mute them
/// and it never reads as urgent. Recategorise them and it stays that way.
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

    /// Fill-on-read, done once, under the lock.
    private static func cached<Value>(
        _ store: Guarded<Value?>,
        load: () -> Value
    ) -> Value {
        store.withLock { held in
            if let held { return held }
            let loaded = load()
            held = loaded
            return loaded
        }
    }

    static var important: Set<String> {
        get {
            cached(importantCache) {
                Set(UserDefaults.standard.stringArray(forKey: importantKey) ?? [])
            }
        }
        set {
            importantCache.withLock { held in held = newValue }
            UserDefaults.standard.set(Array(newValue), forKey: importantKey)
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
    }

    // MARK: - Muted

    static var muted: Set<String> {
        get {
            cached(mutedCache) {
                Set(UserDefaults.standard.stringArray(forKey: mutedKey) ?? [])
            }
        }
        set {
            mutedCache.withLock { held in held = newValue }
            UserDefaults.standard.set(Array(newValue), forKey: mutedKey)
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
    }

    // MARK: - Category

    private static var overrides: [String: String] {
        get {
            cached(overridesCache) {
                UserDefaults.standard.dictionary(forKey: categoryKey) as? [String: String] ?? [:]
            }
        }
        set {
            overridesCache.withLock { held in held = newValue }
            UserDefaults.standard.set(newValue, forKey: categoryKey)
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
                UserDefaults.standard.dictionary(forKey: relationshipKey) as? [String: String] ?? [:]
            }
        }
        set {
            relationshipsCache.withLock { held in held = newValue }
            UserDefaults.standard.set(newValue, forKey: relationshipKey)
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

    static func clearAll() {
        importantCache.withLock { held in held = [] }
        mutedCache.withLock { held in held = [] }
        overridesCache.withLock { held in held = [:] }
        relationshipsCache.withLock { held in held = [:] }
        UserDefaults.standard.removeObject(forKey: importantKey)
        UserDefaults.standard.removeObject(forKey: mutedKey)
        UserDefaults.standard.removeObject(forKey: categoryKey)
        UserDefaults.standard.removeObject(forKey: relationshipKey)
    }
}
