import Foundation

/// What the first import still owes.
///
/// The import used to be a loop with no memory: it walked Gmail's pages, and
/// if one request failed it broke out, wrote `hasImported = true` anyway, and
/// the mailbox was permanently short by however many pages were left. A phone
/// that dropped one request on a train at page six kept 300 emails out of
/// 1,580 and reported itself complete, and nothing ever went back for the
/// rest. Every clever thing above this -- retrieval, reasoning, the model --
/// was searching a mailbox with two thirds of the evidence missing.
///
/// So the import writes down what it is going to fetch before it fetches any
/// of it, and crosses each id off only once that message is safely on disk.
/// Anything still on this list is mail Maily knows it is missing, which is the
/// difference between an import that can be resumed and one that can only be
/// started again.
struct ImportLedger: Codable, Equatable {
    /// Message ids not yet fetched, newest first.
    var pending: [String]
    /// How many have landed. `done + pending.count == total`, always.
    var done: Int
    /// The real denominator, counted from Gmail before any body was fetched.
    var total: Int
    var startedAt: Date

    init(pending: [String], done: Int = 0, total: Int? = nil, startedAt: Date = .now) {
        self.pending = pending
        self.done = done
        self.total = total ?? pending.count
        self.startedAt = startedAt
    }

    var isComplete: Bool { pending.isEmpty }

    /// Stale ledgers are worse than none: the three month window has moved on,
    /// so the ids listed then are no longer the ids to fetch now.
    var isStale: Bool {
        Date.now.timeIntervalSince(startedAt) > 7 * 24 * 60 * 60
    }

    /// The next slice to fetch, and nothing if there is none left.
    func nextChunk(_ size: Int) -> [String]? {
        pending.isEmpty ? nil : Array(pending.prefix(size))
    }

    /// Crosses ids off. The copy in memory is crossed off as messages arrive;
    /// the copy on disk is only ever `save()`d after those messages are, so a
    /// kill between the fetch and the write costs a re-fetch rather than a
    /// hole nobody knows about.
    mutating func complete(_ ids: [String]) {
        let crossed = Set(ids)
        let before = pending.count
        pending.removeAll { crossed.contains($0) }
        done += before - pending.count
    }

    /// Moves ids that would not come to the back, so a poisoned message does
    /// not block the thousand behind it. They stay pending, so a later launch
    /// tries them again.
    mutating func postpone(_ ids: [String]) {
        let moved = Set(ids)
        let rest = pending.filter { !moved.contains($0) }
        pending = rest + pending.filter { moved.contains($0) }
    }

    // MARK: - Storage

    private static let key = "mail.importLedger"

    static func load() -> ImportLedger? {
        guard let data = MailboxScope.defaults.data(forKey: key),
              let ledger = try? JSONDecoder().decode(ImportLedger.self, from: data)
        else { return nil }
        return ledger
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        MailboxScope.defaults.set(data, forKey: Self.key)
    }

    static func clear() {
        MailboxScope.defaults.removeObject(forKey: key)
    }
}
