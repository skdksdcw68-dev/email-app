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
        // Read so that observation tracks it: a preference change re-derives
        // the list.
        _ = preferencesVersion
        return messages.people(myAddress: account.email)
    }
}

extension MailStore {
    /// The tag chips as one line, for the model.
    ///
    /// Costs about fifty tokens and answers a whole class of question the
    /// assistant used to get wrong, because it could see a dozen emails but
    /// not the shape of the inbox they came out of. This is data, not an
    /// answer: what the model does with it is the model's business.
    var tagSummary: String {
        let counts = tagCounts(in: .inbox)
        let parts = AITag.allCases.compactMap { tag -> String? in
            let total = counts.total[tag] ?? 0
            guard total > 0 else { return nil }
            return "\(tag.title) \(total) (\(counts.unread[tag] ?? 0) unread)"
        }
        return parts.joined(separator: ", ")
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
