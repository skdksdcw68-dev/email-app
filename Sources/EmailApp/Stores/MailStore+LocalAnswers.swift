import Foundation

/// The assistant's decision ladder. Every question lands on exactly one rung:
///
///   Level 1 -- understand locally. Questions the mailbox itself can answer
///   ("what needs a reply", "who am I keeping waiting", "what is in Very
///   Urgent") are answered here: instantly, for free, and as structure --
///   stat tiles, tappable message cards, a chart -- rather than prose about
///   numbers.
///
///   Level 2 -- ask the model. Anything open-ended goes to the model with a
///   device-side retrieval digest, streams back as prose, and cites the
///   actual emails it leaned on.
///
///   Never -- act on the mailbox beyond what Maily itself holds. There is no
///   `gmail.modify` scope, so no answer may offer to archive, delete or file
///   anything, and nothing is ever sent without the user reviewing it first.
extension MailStore {

    /// A structured answer when the question is one the mailbox can settle,
    /// nil when it deserves the model.
    func localAnswer(for question: String) -> LocalAnswer? {
        guard !messages.isEmpty else { return nil }
        let q = question.lowercased()

        // Tag questions are exactly answerable however long they run ("what
        // have I got sitting in very important from this week"), so they are
        // settled before the length gate that protects the nuanced ones.
        if let answer = tagAnswer(for: q) { return answer }
        if let answer = tagOverview(for: q) { return answer }

        // Long questions carry nuance ("should I reply to Sara about the
        // invoice before Friday?") that keyword routing would flatten. Only
        // short, generic asks are settled locally.
        guard question.count <= 60 else { return nil }

        func any(_ needles: String...) -> Bool { needles.contains { q.contains($0) } }

        // Who is waiting -- in either direction.
        if any("waiting", "follow up", "follow-up", "keeping") {
            let waiting = followUps.filter { $0.direction == .waitingOnYou }
            let quiet = followUps.filter { $0.direction == .waitingOnThem }

            let text: String
            switch (waiting.count, quiet.count) {
            case (0, 0):
                text = "Nobody is waiting on you, and nothing you sent has gone quiet. All caught up."
            case (0, let them):
                text = them == 1
                    ? "Nobody is waiting on a reply from you. One conversation you started has gone quiet, though."
                    : "Nobody is waiting on a reply from you. \(them) conversations you started have gone quiet, though."
            case (1, _):
                text = "One person is waiting on a reply from you."
            case (let you, _):
                text = "\(you) people are waiting on a reply from you."
            }

            let shown = (waiting.isEmpty ? quiet : waiting).prefix(6).map(\.message)
            return LocalAnswer(text: text, blocks: shown.isEmpty ? [] : [.messages(Array(shown))])
        }

        // What needs a reply, asked the long way round: "what do I need to
        // reply to?" is past the word count `tagAnswer` will take on faith.
        if q.contains("reply") && any("need", "what", "should", "who") {
            let due = messages(in: .inbox, tag: .needsReply)
            guard !due.isEmpty else {
                return LocalAnswer(text: "Nothing is waiting on a reply. Clear.", blocks: [])
            }
            let unread = due.filter { !$0.isRead }.count
            return LocalAnswer(
                text: Self.replyText(total: due.count, unread: unread),
                blocks: [.messages(Array(due.prefix(6)))]
            )
        }

        // What is urgent / needs attention.
        if any("urgent", "attention", "on fire") {
            let counts = self.counts
            let stats = [
                Stat(title: "Urgent", value: "\(counts.urgent)", symbol: "bolt.fill", tint: .red),
                Stat(title: "Need reply", value: "\(counts.needsReply)", symbol: "arrowshape.turn.up.left.fill", tint: .blue),
                Stat(title: "Unread", value: "\(counts.new)", symbol: "envelope.badge.fill", tint: .orange),
            ]
            let attention = needsAttention(limit: 6)
            var blocks: [AnswerBlock] = [.stats(stats)]
            if !attention.isEmpty { blocks.append(.messages(attention)) }
            return LocalAnswer(text: inboxStatus, blocks: blocks)
        }

        // How much mail is there.
        if any("how many", "unread", "how much mail") {
            let counts = self.counts
            let stats = [
                Stat(title: "Unread", value: "\(counts.new)", symbol: "envelope.badge.fill", tint: .blue),
                Stat(title: "Need reply", value: "\(counts.needsReply)", symbol: "arrowshape.turn.up.left.fill", tint: .indigo),
                Stat(title: "Urgent", value: "\(counts.urgent)", symbol: "bolt.fill", tint: .red),
            ]
            return LocalAnswer(text: "Where your inbox stands right now:", blocks: [.stats(stats)])
        }

        // Who emails me most.
        if any("busiest", "who emails", "emails me the most", "most emails", "top senders") {
            let top = topSenders(limit: 6)
            guard !top.isEmpty else { return nil }
            let points = top.map { AnswerChart.Point(label: $0.0, value: $0.1) }
            return LocalAnswer(
                text: "\(top[0].0) tops the list.",
                blocks: [.chart(AnswerChart(title: "Inbox messages by sender", points: points))]
            )
        }

        return nil
    }

    // MARK: - Tags

    /// "What is in Important", "show me very urgent", "how many need a reply".
    ///
    /// The tags are the person's own view of their inbox -- they are what the
    /// chips at the top of the list say -- so the assistant knowing nothing
    /// about them made it noticeably dumber than the screen behind it.
    private func tagAnswer(for q: String) -> LocalAnswer? {
        guard let tag = AITag.named(in: q), Self.isAsking(q) else { return nil }

        let all = messages(in: .inbox, tag: tag)
        guard !all.isEmpty else {
            return LocalAnswer(text: "Nothing is tagged \(tag.title) right now.", blocks: [])
        }

        let unread = all.filter { !$0.isRead }.count
        let wantsEverything = q.contains("list") || q.contains(" all ") || q.hasPrefix("all ")
        let shown = Array(all.prefix(wantsEverything ? 25 : 6))

        let text: String
        if tag == .needsReply {
            text = Self.replyText(total: all.count, unread: unread)
        } else if all.count == 1 {
            text = "One email in \(tag.title):"
        } else if wantsEverything {
            text = "\(all.count) in \(tag.title). All of them:"
        } else if all.count > shown.count {
            text = "\(all.count) in \(tag.title). The newest \(shown.count):"
        } else {
            text = "\(all.count) in \(tag.title):"
        }

        let stats = [
            Stat(tag: tag, count: all.count),
            Stat(title: "Unread", value: "\(unread)", symbol: "envelope.badge.fill", tint: .blue),
            Stat(title: "Read", value: "\(all.count - unread)", symbol: "envelope.open", tint: .green),
        ]

        return LocalAnswer(text: text, blocks: [.stats(stats), .messages(shown)])
    }

    /// "What tags do I have", "give me the breakdown".
    private func tagOverview(for q: String) -> LocalAnswer? {
        let asks = [
            "my tags", "what tags", "which tags", "all tags", "tags do i have",
            "tag breakdown", "breakdown", "by tag", "how is my inbox split",
        ]
        guard asks.contains(where: q.contains) else { return nil }

        let counts = tagCounts(in: .inbox)
        let present = AITag.allCases
            .map { ($0, counts.total[$0] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        guard let biggest = present.first else { return nil }

        let points = present.map { AnswerChart.Point(label: $0.0.title, value: $0.1) }
        let stats = present.prefix(3).map { Stat(tag: $0.0, count: $0.1) }

        return LocalAnswer(
            text: "\(biggest.0.title) is your biggest pile, at \(biggest.1).",
            blocks: [.stats(Array(stats)), .chart(AnswerChart(title: "Inbox by tag", points: points))]
        )
    }

    /// Reply wording that softens once the person has actually seen the mail.
    ///
    /// Telling someone to reply to an email they read three days ago and
    /// chose not to answer is nagging. What they have not opened is news and
    /// can be stated plainly; what they have opened is a recommendation.
    private static func replyText(total: Int, unread: Int) -> String {
        guard total > 0 else { return "Nothing is waiting on a reply. Clear." }
        let read = total - unread

        if unread == 0 {
            return total == 1
                ? "One you have already read is still unanswered. Worth a reply when you get to it."
                : "\(total) you have already read are still unanswered. Worth a reply when you have a minute, no rush."
        }
        if read == 0 {
            return total == 1
                ? "One email is waiting on a reply:"
                : "\(total) emails are waiting on a reply. The most recent first:"
        }
        return "\(total) are unanswered. \(unread) you have not opened yet; the other \(read) you have read, so treat those as a suggestion."
    }

    /// Whether the tag word is part of a question about that pile, rather
    /// than a word that merely turned up in a sentence. "What did Sara say
    /// about the meeting" is a question for the model, not a request for the
    /// Meeting chip.
    private static func isAsking(_ q: String) -> Bool {
        let listing = [
            "how many", "how much", "show me", "show ", "list ", "give me",
            "tell me", "what's in", "what is in", "whats in", "what do i have",
            "what have i", "anything in", "do i have", "sitting in", "read out",
        ]
        if listing.contains(where: q.contains) { return true }
        // A short phrase built around the tag name is a request for that pile:
        // "what is important", "very urgent", "unanswered?".
        return q.split(separator: " ").count <= 5
    }

    // MARK: - What the model is told

    /// The tag chips, as one line for the model.
    ///
    /// Costs almost nothing and answers a whole class of question the model
    /// used to get wrong, because it could see a dozen emails but not the
    /// shape of the inbox they came from.
    var tagSummary: String {
        let counts = tagCounts(in: .inbox)
        let parts = AITag.allCases.compactMap { tag -> String? in
            let total = counts.total[tag] ?? 0
            guard total > 0 else { return nil }
            return "\(tag.title) \(total) (\(counts.unread[tag] ?? 0) unread)"
        }
        return parts.joined(separator: ", ")
    }

    private func topSenders(limit: Int) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for message in messages(in: .inbox) {
            counts[message.sender.name, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }
}
