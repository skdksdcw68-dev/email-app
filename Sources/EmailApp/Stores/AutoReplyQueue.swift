import Foundation
import Observation

/// Every decision Auto-Reply has made, and the replies still waiting.
///
/// Kept on the phone with the mail it came from, and cleared with it: a
/// drafted reply quotes an email, so it is mail content and it goes when the
/// mailbox goes. The setup in `AutoReplyStore` is the opposite -- that is
/// what they taught Maily about themselves, and it stays.
///
/// The log keeps skips as well as drafts. The question somebody actually
/// asks is "why didn't it answer this one?", and only a record that includes
/// the ones it walked past can answer that.
@Observable
@MainActor
final class AutoReplyQueue {

    /// Newest first.
    private(set) var decisions: [AutoReplyDecision] = []

    /// Message ids already decided about, so nothing is considered twice.
    private(set) var handled: Set<String> = []

    /// A pass is running. Drives the skeleton, so "nothing happened" and
    /// "still looking" are never the same screen.
    private(set) var isChecking = false
    /// When a pass last finished, so the screen can say how fresh it is.
    private(set) var lastCheckedAt: Date?

    func beginCheck() { isChecking = true }

    func endCheck() {
        isChecking = false
        lastCheckedAt = .now
    }

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
            .appending(path: "autoreply-queue.json")
    }

    // MARK: - Reading

    /// Replies written and waiting to be sent. What the badge counts.
    var waiting: [AutoReplyDecision] {
        decisions.filter(\.isWaiting)
    }

    /// Everything it looked at, drafts and skips alike.
    var log: [AutoReplyDecision] { decisions }

    func hasDecided(_ remoteID: String) -> Bool {
        handled.contains(remoteID)
    }

    // MARK: - Writing

    func record(_ decision: AutoReplyDecision) {
        handled.insert(decision.messageID)
        decisions.removeAll { $0.messageID == decision.messageID }
        decisions.insert(decision, at: 0)
        if decisions.count > Self.limit {
            decisions = Array(decisions.prefix(Self.limit))
        }
        persist()
    }

    /// The person sent it, so it stops waiting.
    func markSent(_ id: AutoReplyDecision.ID) {
        update(id) {
            $0.outcome = .sent
            $0.reason = "You sent this."
        }
    }

    /// The person threw it away. Kept in the log rather than deleted, so
    /// "Maily keeps writing replies I don't want" is a thing they can see
    /// evidence for rather than a feeling.
    func discard(_ id: AutoReplyDecision.ID) {
        update(id) {
            $0.outcome = .skipped
            $0.reason = "You threw this one away."
            $0.reply = nil
        }
    }

    /// A failed attempt is allowed to be tried again on a later pass.
    func allowRetry(_ messageID: String) {
        handled.remove(messageID)
        decisions.removeAll { $0.messageID == messageID }
        persist()
    }

    fileprivate func update(_ id: AutoReplyDecision.ID, _ change: (inout AutoReplyDecision) -> Void) {
        guard let index = decisions.firstIndex(where: { $0.id == id }) else { return }
        change(&decisions[index])
        persist()
    }

    /// Enough to see a pattern, not enough to become its own storage
    /// problem. Skips are the bulk of it and they are one line each.
    static let limit = 500

    // MARK: - Disk

    private struct Stored: Codable {
        var decisions: [AutoReplyDecision]
        var handled: [String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        decisions = stored.decisions
        handled = Set(stored.handled)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Stored(decisions: decisions, handled: Array(handled)))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A lost decision means one email gets looked at twice, which
            // costs a fraction of a penny and no correctness.
        }
    }

    func clearAll() {
        decisions = []
        handled = []
        lastCheckedAt = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}

extension AutoReplyQueue {

    /// How many replies Maily has sent on its own in the last hour.
    ///
    /// The rate limit is the difference between one bad setup being a
    /// mistake and it being forty messages to forty strangers. It counts
    /// only autonomous sends: a person pressing send forty times is a person
    /// answering their mail, which is the point of the app.
    func autoSentInLastHour(now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-3600)
        return decisions.filter { $0.outcome == .sent && $0.wasAutoSent && $0.decidedAt > cutoff }.count
    }

    /// Whether Maily has already answered this conversation on its own.
    ///
    /// Once per thread, ever. A thread where somebody keeps writing back is
    /// a conversation, and a conversation is a person's job -- the value here
    /// is answering the first "what do you charge", not conducting the
    /// negotiation that follows.
    func hasAutoSent(inThread threadID: String?) -> Bool {
        guard let threadID else { return false }
        return decisions.contains {
            $0.threadID == threadID && $0.outcome == .sent && $0.wasAutoSent
        }
    }

    /// Records a reply Maily sent itself.
    func markAutoSent(_ id: AutoReplyDecision.ID) {
        update(id) {
            $0.outcome = .sent
            $0.wasAutoSent = true
            $0.reason = "Maily sent this for you."
        }
    }
}
