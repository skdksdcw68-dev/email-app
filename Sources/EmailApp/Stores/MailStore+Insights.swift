import Foundation

/// Everything the Home screen shows is derived from the mailbox here, rather
/// than hardcoded in a view. When real Gmail replaces the sample data, the Home
/// screen becomes true on its own.
extension MailStore {

    // MARK: - The counts strip

    var counts: InboxCounts {
        let inbox = messages(in: .inbox)
        return InboxCounts(
            new: inbox.filter { !$0.isRead }.count,
            important: inbox.filter { $0.tags.contains(.important) || $0.tags.contains(.veryImportant) }.count,
            needsReply: inbox.filter { $0.tags.contains(.needsReply) }.count,
            urgent: inbox.filter { $0.tags.contains(.urgent) }.count
        )
    }

    /// The one-line status under the greeting.
    var inboxStatus: String {
        let counts = self.counts
        if !isConnected { return "Connect an inbox to get started." }
        if counts.urgent > 0 {
            return counts.urgent == 1
                ? "One email needs you right away."
                : "\(counts.urgent) emails need you right away."
        }
        if counts.needsReply > 0 {
            return counts.needsReply == 1
                ? "One reply is waiting on you."
                : "\(counts.needsReply) replies are waiting on you."
        }
        return "Your inbox is under control."
    }

    // MARK: - Needs your attention

    /// Urgent first, then anything else awaiting a reply. This is the first
    /// meaningful thing on the screen, so it stays short on purpose.
    func needsAttention(limit: Int = 3) -> [Message] {
        messages(in: .inbox)
            // Unread as well as important. Without this, marking everything
            // read left the list exactly as it was, and nothing the user did
            // could ever clear it. Anything read but still unanswered is not
            // lost -- it is in Follow-ups, which is the right home for it.
            .filter { !$0.isRead }
            .filter { $0.tags.contains(.urgent) || $0.tags.contains(.needsReply) }
            .sorted { lhs, rhs in
                let l = lhs.topPriority?.priorityRank ?? Int.max
                let r = rhs.topPriority?.priorityRank ?? Int.max
                return l == r ? lhs.date > rhs.date : l < r
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Maily recommends

    var recommendations: [Recommendation] {
        var result: [Recommendation] = []
        let inbox = messages(in: .inbox)

        let followUps = inbox.filter { $0.tags.contains(.needsReply) && $0.isRead }
        if followUps.count > 1 {
            result.append(
                Recommendation(
                    id: "follow_ups",
                    symbol: "arrow.uturn.left.circle.fill",
                    text: "\(followUps.count) conversations may need a follow-up.",
                    actionLabel: "Review",
                    tag: .needsReply
                )
            )
        }

        let clutter = inbox.filter { $0.tags.contains(.noReplyNeeded) }
        if clutter.count > 1 {
            result.append(
                Recommendation(
                    id: "clutter",
                    symbol: "tray.2.fill",
                    text: "\(clutter.count) messages need nothing from you. Want Maily to file them?",
                    actionLabel: "Organize",
                    tag: .noReplyNeeded
                )
            )
        }

        let unread = inbox.filter { !$0.isRead && $0.tags.contains(.important) }
        if !unread.isEmpty {
            result.append(
                Recommendation(
                    id: "unread_important",
                    symbol: "sparkles",
                    text: "\(unread.count) important messages are still unread.",
                    actionLabel: "Read",
                    tag: .important
                )
            )
        }

        return result
    }

    // MARK: - Your day

    /// Built from mail that carries a time-bound commitment. Real calendar
    /// events join this list once the user grants calendar access -- until then
    /// the section simply hides when there is nothing to show.
    var dayItems: [DayItem] {
        messages(in: .inbox)
            .filter { $0.tags.contains(.urgent) || $0.tags.contains(.veryImportant) }
            .sorted { $0.date < $1.date }
            .map {
                DayItem(id: $0.id, date: $0.date, title: $0.subject, detail: $0.sender.name)
            }
    }

    // MARK: - People

    /// Correspondents assembled from their messages, busiest relationships,
    /// anyone marked important, and anyone left waiting first.
    var people: [Person] {
        guard let account else { return [] }
        return messages.people(myAddress: account.email)
    }
}

extension Date {
    /// "Good morning" / "Good afternoon" / "Good evening".
    static var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}
