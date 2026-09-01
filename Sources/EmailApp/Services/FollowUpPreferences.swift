import Foundation

/// Follow-ups the person has waved away.
///
/// A list that cannot be cleared stops being a list and becomes wallpaper.
/// Dismissal is per conversation and dated: if the thread moves again after
/// it was dismissed -- they finally replied, or you sent another chase -- it
/// comes back, because it is a different situation now.
enum FollowUpPreferences {

    private static let key = "followups.dismissed"

    private static var dismissals: [String: Date] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else {
                return [:]
            }
            return raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            UserDefaults.standard.set(
                newValue.mapValues(\.timeIntervalSince1970), forKey: key
            )
        }
    }

    static func dismiss(_ id: String) {
        var current = dismissals
        current[id] = .now
        dismissals = current
    }

    static func restore(_ id: String) {
        var current = dismissals
        current.removeValue(forKey: id)
        dismissals = current
    }

    /// True when this conversation was dismissed and nothing has happened in
    /// it since.
    static func isDismissed(_ id: String, lastActivity: Date) -> Bool {
        guard let dismissedAt = dismissals[id] else { return false }
        return lastActivity <= dismissedAt
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
