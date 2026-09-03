import Foundation

/// How much of the AI the app has actually used this month.
///
/// Maily runs on the person's own key, so the bill is theirs and the only
/// place it is visible is a website they have to go and look at. That is a
/// bad way to find out you have run out -- which is exactly how it goes
/// wrong: everything stops working at once and nothing in the app says why.
///
/// So the app counts what it asks for, on the device, by what it was for.
/// Not tokens: nobody can act on a token count, and the app cannot see the
/// bill anyway. What it can say is "you asked 40 questions and read 1,600
/// emails this month", which is the sentence that explains the number on the
/// website.
///
/// Nothing here leaves the phone.
enum AIUsage {

    /// What an AI call was for, in the terms somebody would use about it.
    /// Deliberately not the action names: "ask_stream" is plumbing.
    enum Kind: String, CaseIterable, Codable {
        case reading
        case questions
        case writing
        case searching
        case autoReply

        /// Which of these a server action counts as.
        init(action: String) {
            switch action {
            case "classify", "extract": self = .reading
            case "ask", "ask_stream": self = .questions
            case "draft", "refine", "revise": self = .writing
            case "search": self = .searching
            default: self = .autoReply
            }
        }

        var title: String {
            switch self {
            case .reading: "Reading your mail"
            case .questions: "Questions you asked"
            case .writing: "Writing for you"
            case .searching: "Searching"
            case .autoReply: "Auto-Reply"
            }
        }

        var detail: String {
            switch self {
            case .reading: "Sorting and tagging what arrives. The cheap one."
            case .questions: "Every question in the chat, including the times it looked twice."
            case .writing: "Drafts, polish and rewrites you asked for."
            case .searching: "Turning what you described into a Gmail search."
            case .autoReply: "Setting it up, and every reply it wrote."
            }
        }

        var symbol: String {
            switch self {
            case .reading: "tray.full.fill"
            case .questions: "bubble.left.and.text.bubble.right.fill"
            case .writing: "square.and.pencil"
            case .searching: "magnifyingglass"
            case .autoReply: "arrowshape.turn.up.left.2.fill"
            }
        }

        /// Roughly what one of these costs relative to the others. Not a
        /// price -- the app cannot see the bill -- but the difference between
        /// a question and a classified email is real and worth showing, and
        /// somebody wondering where their credit went deserves the hint.
        var isExpensive: Bool {
            self == .questions || self == .writing || self == .autoReply
        }
    }

    private static let key = "ai.usage"

    /// This month's counts, and which month they belong to.
    private struct Stored: Codable {
        var month: String
        var counts: [String: Int]
    }

    /// Behind a lock, and it has to be.
    ///
    /// `record` is called from `AIService.call`, which is not on any actor,
    /// and `enhanceWithAI` runs fifteen of those at once. This used to be a
    /// `nonisolated(unsafe) static var` incremented by all fifteen with no
    /// barrier -- which is a refcounted store to shared memory from fifteen
    /// threads. It corrupted the heap and killed the app in an unrelated
    /// Keychain call about a minute after launch, every time.
    ///
    /// Read from SwiftUI `body` as well, which is why this is a lock and not
    /// an actor. See `Guarded`.
    private static let state = Guarded<Stored?>(nil)

    /// Counted at the one place every call goes through, so nothing can be
    /// spent without appearing here.
    static func record(action: String) {
        let kind = Kind(action: action).rawValue
        let month = monthKey

        let updated: Stored = state.withLock { held in
            var stored = Self.loaded(held, month: month)
            stored.counts[kind, default: 0] += 1
            held = stored
            return stored
        }

        // Outside the lock. Encoding and writing a plist is far too much work
        // to do while fifteen other threads spin waiting for it.
        guard let data = try? JSONEncoder().encode(updated) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func count(of kind: Kind) -> Int {
        current().counts[kind.rawValue] ?? 0
    }

    static var total: Int {
        current().counts.values.reduce(0, +)
    }

    /// Only the kinds that have actually been used, busiest first.
    static var used: [(kind: Kind, count: Int)] {
        Kind.allCases
            .map { ($0, count(of: $0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    static var monthName: String {
        Date.now.formatted(.dateTime.month(.wide).year())
    }

    static func reset() {
        state.withLock { held in held = nil }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Drops what is held in memory without touching what was written, which
    /// is what a cold launch looks like. Only the tests need it; the app gets
    /// this for free by starting.
    static func forgetInMemory() {
        state.withLock { held in held = nil }
    }

    /// This month's counts, starting fresh when the month turns over. A
    /// running total since install would only ever grow, which tells nobody
    /// anything about whether this month is unusual.
    ///
    /// Under the lock, because this *writes* on the read path -- it fills the
    /// cache from disk on first ask. Guarding only `record` would have left
    /// half the race in place.
    private static func current() -> Stored {
        let month = monthKey
        return state.withLock { held in
            let stored = Self.loaded(held, month: month)
            held = stored
            return stored
        }
    }

    /// What is held, if it is still this month, else what is on disk, else a
    /// fresh empty month. Pure, and called with the lock already taken.
    private static func loaded(_ held: Stored?, month: String) -> Stored {
        if let held, held.month == month { return held }

        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.month == month
        else {
            return Stored(month: month, counts: [:])
        }
        return stored
    }

    private static var monthKey: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: .now)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }
}
