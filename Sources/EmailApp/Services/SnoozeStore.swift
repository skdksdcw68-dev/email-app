import Foundation

/// Mail put away until a day that suits.
///
/// The one thing an inbox is bad at: a message that matters, but not today.
/// Reading it and leaving it unread is a lie you tell yourself; reading it
/// and letting it slide down is how it gets lost.
///
/// Local only, and it has to be. Snoozing in Gmail means moving a message out
/// of the inbox and back, which is `gmail.modify`, which Maily does not have
/// and will not ask for -- see the scope note in `GmailService`. So a snoozed
/// message is hidden here and shown again here, and it stays exactly where it
/// is in Gmail the whole time. On the web it never moved. That is the honest
/// trade, and the app says so rather than implying the two are in step.
enum SnoozeStore {

    private static let key = "mail.snoozed"

    /// Gmail's id to the day it comes back. Held in memory because the
    /// inbox list asks about every message it draws.
    nonisolated(unsafe) private static var cached: [String: Date]?

    private static var snoozed: [String: Date] {
        get {
            if let cached { return cached }
            let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
            let loaded = raw.mapValues { Date(timeIntervalSince1970: $0) }
            cached = loaded
            return loaded
        }
        set {
            cached = newValue
            UserDefaults.standard.set(newValue.mapValues(\.timeIntervalSince1970), forKey: key)
        }
    }

    // MARK: - Putting away

    static func snooze(_ remoteID: String, until date: Date) {
        var all = snoozed
        all[remoteID] = date
        snoozed = all
    }

    static func wake(_ remoteID: String) {
        var all = snoozed
        all.removeValue(forKey: remoteID)
        snoozed = all
    }

    /// Whether this is put away right now. False the moment its day arrives,
    /// without anything having to run: the comparison is the whole mechanism,
    /// so a phone that was off all week still shows the right thing.
    static func isAsleep(_ remoteID: String?, now: Date = .now) -> Bool {
        guard let remoteID, let until = snoozed[remoteID] else { return false }
        return until > now
    }

    static func wakesAt(_ remoteID: String?) -> Date? {
        guard let remoteID, let until = snoozed[remoteID], until > .now else { return nil }
        return until
    }

    /// Everything still put away, soonest first.
    static func sleeping(now: Date = .now) -> [(id: String, until: Date)] {
        snoozed
            .filter { $0.value > now }
            .map { (id: $0.key, until: $0.value) }
            .sorted { $0.until < $1.until }
    }

    /// Drops anything whose day has passed, so the store does not grow for
    /// ever. Returns whether anything actually came back, which is what tells
    /// the inbox it has a message to show again.
    @discardableResult
    static func forgetWoken(now: Date = .now) -> Bool {
        let live = snoozed.filter { $0.value > now }
        guard live.count != snoozed.count else { return false }
        snoozed = live
        return true
    }

    static func clearAll() {
        cached = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - When

    /// The choices worth offering. Anything more precise is a date picker,
    /// which is there for the one person who wants Tuesday at 4.
    enum When: String, CaseIterable, Identifiable {
        case laterToday, tomorrow, thisWeekend, nextWeek

        var id: Self { self }

        var title: String {
            switch self {
            case .laterToday: "Later today"
            case .tomorrow: "Tomorrow"
            case .thisWeekend: "This weekend"
            case .nextWeek: "Next week"
            }
        }

        var symbol: String {
            switch self {
            case .laterToday: "clock"
            case .tomorrow: "sunrise"
            case .thisWeekend: "beach.umbrella"
            case .nextWeek: "calendar"
            }
        }

        /// Morning, not midnight. A message that comes back at 00:01 is a
        /// message you meet at the bottom of the inbox having missed it.
        func date(from now: Date = .now) -> Date {
            let calendar = Calendar.current
            switch self {
            case .laterToday:
                return calendar.date(byAdding: .hour, value: 3, to: now) ?? now
            case .tomorrow:
                return morning(after: 1, from: now)
            case .thisWeekend:
                // Saturday, or next Saturday if it is already the weekend.
                let weekday = calendar.component(.weekday, from: now)
                let days = weekday >= 7 ? 7 : 7 - weekday
                return morning(after: max(1, days), from: now)
            case .nextWeek:
                let weekday = calendar.component(.weekday, from: now)
                // Monday: 9 is "next Monday" from a Sunday.
                let days = weekday == 1 ? 1 : 9 - weekday
                return morning(after: days, from: now)
            }
        }

        private func morning(after days: Int, from now: Date) -> Date {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: days, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
        }
    }
}
