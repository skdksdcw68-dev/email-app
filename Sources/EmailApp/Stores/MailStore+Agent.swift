import Foundation

/// Working out which email, and which person, a draft request is about.
///
/// The agent's rule is to be decisive when the mailbox is, and to ask when
/// it is not. One clear match becomes a draft; several equally good matches
/// become a question with the candidates laid out; no match becomes a
/// question about who was meant. It never guesses and writes to the wrong
/// person.
extension MailStore {

    /// Emails a request could be about, best match first. Every result is a
    /// genuine tie for best; anything weaker is left out so the caller can
    /// treat "more than one" as real ambiguity.
    ///
    /// `offered` is what Maily just showed the person, so "the first one"
    /// and "reply to it" have something to refer to. `within` narrows the
    /// search to a given set -- the answer to "which one?" is chosen from
    /// the ones that were offered, not from the whole inbox again.
    func draftCandidates(
        for request: DraftRequest,
        offered: [Message],
        within pool: [Message]? = nil
    ) -> [Message] {
        if let ordinal = request.ordinal, !offered.isEmpty {
            if ordinal < 0, let newest = offered.max(by: { $0.date < $1.date }) { return [newest] }
            if ordinal >= 1, ordinal <= offered.count { return [offered[ordinal - 1]] }
        }

        // "reply to it", "answer that": whatever was just on screen.
        if request.hints.isEmpty { return offered }

        let mine = account?.address.lowercased()
        var scored: [(message: Message, score: Int)] = []

        for message in pool ?? messages(in: .inbox) {
            if let mine, message.sender.address.lowercased() == mine { continue }

            let name = message.sender.name.lowercased()
            let address = message.sender.address.lowercased()
            let subject = message.subject.lowercased()

            var score = 0
            for hint in request.hints {
                if name.contains(hint) || address.contains(hint) {
                    score += 10
                } else if subject.contains(hint) {
                    score += 4
                }
            }
            guard score > 0 else { continue }
            // Something still waiting on a reply is the likelier target.
            if message.tags.contains(.needsReply) { score += 2 }
            scored.append((message, score))
        }

        let ranked = scored.sorted { left, right in
            left.score == right.score ? left.message.date > right.message.date : left.score > right.score
        }
        guard let best = ranked.first?.score else { return [] }
        return ranked.filter { $0.score == best }.prefix(4).map(\.message)
    }

    /// Somebody to write a fresh email to, when the hints name a person
    /// rather than an email.
    func contact(matching hints: [String]) -> Contact? {
        guard !hints.isEmpty else { return nil }
        return people.first { person in
            let name = person.contact.name.lowercased()
            let address = person.contact.address.lowercased()
            return hints.contains { name.contains($0) || address.contains($0) }
        }?.contact
    }
}
