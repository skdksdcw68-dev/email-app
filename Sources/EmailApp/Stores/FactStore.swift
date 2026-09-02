import Foundation
import Observation

/// What the mail actually committed people to, kept where the app can sort
/// it, date it and cross it off.
///
/// One JSON file in Application Support, like the chat history, and for the
/// same reasons: a fact is a line of text and there are hundreds at most.
/// These are read out of mail content, so they live and die with the
/// mailbox -- disconnecting clears them, and nothing here is ever sent
/// anywhere for storage. The model sees a handful per question, in the
/// prompt, and that is all.
@Observable
@MainActor
final class FactStore {

    /// Newest message first.
    private(set) var facts: [Fact] = []

    /// Every message the second tier has read, including the ones it found
    /// nothing in. Reading a message twice is paying twice for one answer.
    private(set) var extracted: Set<String> = []

    let fileURL: URL
    nonisolated(unsafe) private var disconnectObserver: NSObjectProtocol?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        load()

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .mailboxDisconnected, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearAll() }
        }
    }

    deinit {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    private static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Maily", directoryHint: .isDirectory)
            .appending(path: "facts.json")
    }

    // MARK: - Recording

    func hasExtracted(_ remoteID: String) -> Bool {
        extracted.contains(remoteID)
    }

    /// What one message yielded, which may be nothing. The message is marked
    /// read either way.
    func record(_ new: [Fact], from remoteID: String) {
        extracted.insert(remoteID)
        // A second read of the same message replaces the first, so a retry
        // cannot double every ask in it.
        facts.removeAll { $0.messageID == remoteID }
        facts += new
        facts.sort { $0.date > $1.date }
        persist()
    }

    func markDone(_ id: Fact.ID, _ done: Bool = true) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[index].isDone = done
        persist()
    }

    // MARK: - Reading

    /// Still live. Not crossed off, not aged out.
    var open: [Fact] {
        facts.filter { !$0.isDone }
    }

    /// The ones the person has to act on.
    var onMe: [Fact] {
        open.filter { $0.isOnMe && $0.kind != .date }
    }

    /// What has a day attached and has not passed: due dates and events,
    /// soonest first, with anything already overdue at the top.
    func upcoming(within days: Int = 14, now: Date = .now) -> [Fact] {
        let calendar = Calendar.current
        guard let horizon = calendar.date(byAdding: .day, value: days, to: now) else { return [] }
        return open
            .filter { fact in
                guard let due = fact.due else { return false }
                return due <= horizon
            }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// Open facts on a conversation, for the row that shows it.
    func facts(inThread threadID: String?) -> [Fact] {
        guard let threadID else { return [] }
        return open.filter { $0.threadID == threadID && $0.kind != .date }
    }

    /// What goes in the prompt: everything still open, dated things first,
    /// then the newest, capped so a busy quarter does not become a page.
    /// The model is told whose move each is and which message it came from.
    static let promptLimit = 30

    func forPrompt(now: Date = .now) -> [Fact] {
        let live = open
        let dated = live.filter { $0.due != nil }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let undated = live.filter { $0.due == nil }
        return Array((dated + undated).prefix(Self.promptLimit))
    }

    /// The prompt lines, numbered against the messages the model will see.
    static func describe(_ facts: [Fact], numbered messages: [Message], now: Date = .now) -> String {
        guard !facts.isEmpty else { return "" }
        var numbers: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let remoteID = message.remoteID, numbers[remoteID] == nil { numbers[remoteID] = index + 1 }
        }
        return facts
            .map { "- " + $0.describe(number: numbers[$0.messageID], now: now) }
            .joined(separator: "\n")
    }

    // MARK: - Keeping it true

    /// A conversation moving on is how most of these get crossed off, without
    /// anybody having to.
    ///
    /// Something on me is done once I write back in that thread after it;
    /// something on them is done once they do. `replied` is the set the app
    /// keeps of messages answered from inside Maily, which is a reply even
    /// when the sent copy has not come back from Gmail yet. A date is done
    /// the day after. Anything past its due date by a month, or with no date
    /// and older than six weeks, has stopped being a reminder and become
    /// clutter, so it goes; and nothing is kept past ninety days.
    func reconcile(with messages: [Message], myAddress: String, replied: Set<String> = [], now: Date = .now) {
        let mine = myAddress.lowercased()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        var byThread: [String: [Message]] = [:]
        for message in messages {
            guard let thread = message.threadID else { continue }
            byThread[thread, default: []].append(message)
        }

        var changed = false
        var kept: [Fact] = []

        for var fact in facts {
            let age = calendar.dateComponents([.day], from: fact.date, to: now).day ?? 0
            if age > 90 { changed = true; continue }

            if !fact.isDone {
                if fact.kind == .date, let due = fact.due, calendar.startOfDay(for: due) < today {
                    fact.isDone = true
                } else if fact.isOnMe, replied.contains(fact.messageID) {
                    fact.isDone = true
                } else if let thread = fact.threadID, let later = byThread[thread] {
                    let answered = later.contains { message in
                        guard message.date > fact.date else { return false }
                        let fromMe = message.mailbox == .sent || message.sender.address.lowercased() == mine
                        return fact.isOnMe ? fromMe : !fromMe
                    }
                    if answered { fact.isDone = true }
                }

                if !fact.isDone {
                    if let due = fact.due,
                       let stale = calendar.date(byAdding: .day, value: 30, to: due), stale < now {
                        changed = true; continue
                    }
                    if fact.due == nil, age > 45 {
                        changed = true; continue
                    }
                }
            }

            kept.append(fact)
        }

        if changed || kept != facts {
            facts = kept
            persist()
        }
    }

    // MARK: - Disk

    private struct Stored: Codable {
        var facts: [Fact]
        var extracted: [String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        facts = stored.facts.sorted { $0.date > $1.date }
        extracted = Set(stored.extracted)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // The read set is a few thousand ids at most: the import window
            // is three months, and an id is forty bytes.
            let stored = Stored(facts: facts, extracted: Array(extracted))
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A lost fact is re-read from the message next time. Not worth
            // interrupting anything over.
        }
    }

    func clearAll() {
        facts = []
        extracted = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}
