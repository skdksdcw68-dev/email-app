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

    static var important: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: importantKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: importantKey) }
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
        get { Set(UserDefaults.standard.stringArray(forKey: mutedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: mutedKey) }
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
        get { UserDefaults.standard.dictionary(forKey: categoryKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: categoryKey) }
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
        UserDefaults.standard.removeObject(forKey: importantKey)
        UserDefaults.standard.removeObject(forKey: mutedKey)
        UserDefaults.standard.removeObject(forKey: categoryKey)
    }
}
