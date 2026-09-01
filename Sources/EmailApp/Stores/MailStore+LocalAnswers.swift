import Foundation

/// The assistant's decision ladder. Every question lands on exactly one rung:
///
///   Level 1 -- understand locally. Questions the mailbox itself can answer
///   ("what needs a reply", "who am I keeping waiting", "how many unread")
///   are answered here: instantly, for free, and as structure -- stat tiles,
///   tappable message cards, a chart -- rather than prose about numbers.
///
///   Level 2 -- ask the model. Anything open-ended goes to the model with a
///   device-side retrieval digest, streams back as prose, and cites the
///   actual emails it leaned on.
///
///   Never -- act on the mailbox. Maily holds no `gmail.modify` scope, so no
///   answer may offer to archive, delete, file or "clean up" anything, and
///   nothing is ever sent without the user reviewing it first.
extension MailStore {

    /// A structured answer when the question is one the mailbox can settle,
    /// nil when it deserves the model.
    func localAnswer(for question: String) -> LocalAnswer? {
        guard !messages.isEmpty else { return nil }
        // Long questions carry nuance ("should I reply to Sara about the
        // invoice before Friday?") that keyword routing would flatten. Only
        // short, generic asks are settled locally.
        guard question.count <= 60 else { return nil }

        let q = question.lowercased()
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

        // What needs a reply.
        if q.contains("reply") && any("need", "what", "should", "who") {
            let due = messages(in: .inbox, tag: .needsReply)
            if due.isEmpty {
                return LocalAnswer(text: "Nothing is waiting on a reply. Clear.", blocks: [])
            }
            let text = due.count == 1
                ? "One email needs a reply:"
                : "\(due.count) emails need a reply. The most recent first:"
            return LocalAnswer(text: text, blocks: [.messages(Array(due.prefix(6)))])
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
