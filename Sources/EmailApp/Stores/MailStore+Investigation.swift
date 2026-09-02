import Foundation

/// Looking for evidence, rather than running a query.
///
/// The old shape was one question, one Gmail query, one set of results, and
/// an answer. That works when the question happens to be phrased the way the
/// email was written, and falls over the rest of the time: "when was my
/// Upwork account created" is not a search, it is a question about a date
/// that lives in an email nobody remembers the wording of. You could get an
/// answer out of it by typing "welcome to upwork" yourself, which is the
/// user doing the retrieval and the app taking the credit.
///
/// So the model proposes several hypotheses about what the evidence would
/// look like, and this runs them. Two layers, cheap first:
///
///   1. **What is already here.** The three months on the phone, searched
///      properly. Instant, free, and after the import fix it is the whole
///      window rather than whatever survived a dropped request.
///   2. **The account.** Gmail's index, which reaches back years. One
///      request per hypothesis, and only while there is still not enough.
///
/// Then everything is ranked together and the extremes are kept, because
/// "when did this start" is answered by the oldest match and "what is the
/// latest" by the newest, and a list sorted one way loses the other.
extension MailStore {

    /// What a round of looking turned up, and what it did to get there.
    struct Investigation {
        var found: [Message] = []
        /// One per thing actually attempted, counted from its own results.
        var steps: [TaskStep] = []
        /// The hypothesis that produced the results, for the caption.
        var answered: String?

        var isEmpty: Bool { found.isEmpty }
    }

    /// Runs the model's hypotheses and returns the evidence, best first.
    func investigate(_ hypotheses: [String], limit: Int = 8) async -> Investigation {
        var report = Investigation()
        guard !hypotheses.isEmpty else { return report }

        var pool: [Message] = []
        var seen = Set<String>()

        // Layer one: the mail already on this phone. Free and instant, so it
        // runs for every hypothesis before anything is paid for.
        for hypothesis in hypotheses {
            let local = localMatches(for: hypothesis, limit: limit)
            report.steps.append(.searchedLocally(hypothesis, found: local))
            for message in local where seen.insert(message.remoteID ?? message.id.uuidString).inserted {
                pool.append(message)
            }
            if report.answered == nil, !local.isEmpty { report.answered = hypothesis }
        }

        // Layer two: the account. Years deeper than the phone, and the only
        // place an old registration email can be.
        guard isConnected, let token = try? await AuthService.currentGmailAccessToken() else {
            report.found = rank(pool, against: hypotheses, limit: limit)
            return report
        }

        for hypothesis in hypotheses {
            // Enough evidence already, and every further request costs. The
            // first hypothesis always runs: the phone holding a match is not
            // proof the account does not hold an older one.
            if pool.count >= limit, hypothesis != hypotheses[0] { break }

            var remote: [Message] = []
            for query in Self.widening(from: hypothesis, terms: [], raw: hypothesis) {
                guard let page = try? await GmailService.fetchInbox(
                    accessToken: token, limit: limit, query: query, label: nil
                ), !page.messages.isEmpty else { continue }
                remote = page.messages
                break
            }

            report.steps.append(.searched(hypothesis, found: remote))
            guard !remote.isEmpty else { continue }

            absorb(remote)
            for message in remote where seen.insert(message.remoteID ?? message.id.uuidString).inserted {
                pool.append(message)
            }
            if report.answered == nil { report.answered = hypothesis }
        }

        report.found = rank(pool, against: hypotheses, limit: limit)
        if !report.found.isEmpty {
            report.steps.append(.reading(report.found))
        }
        return report
    }

    // MARK: - Layer one

    /// The mail on this phone, scored rather than filtered.
    ///
    /// Where a word lands decides what it is worth. A name in the subject or
    /// the sender is what a person remembers a message by; the same word in
    /// the body of an unrelated newsletter is nearly nothing, and treating
    /// the two the same is what used to make "registration date" match a
    /// meeting invitation.
    func localMatches(for query: String, limit: Int) -> [Message] {
        let terms = Highlight.terms(in: query)
        guard !terms.isEmpty else { return [] }

        let scored = messages.compactMap { message -> (Message, Int)? in
            let subject = message.subject.lowercased()
            let who = "\(message.sender.name) \(message.sender.address)".lowercased()
            let body = message.body.lowercased()

            var score = 0
            for term in terms {
                let word = term.lowercased()
                if subject.contains(word) { score += 4 }
                if who.contains(word) { score += 4 }
                if body.contains(word) { score += 1 }
            }
            return score > 0 ? (message, score) : nil
        }

        return scored
            .sorted { left, right in
                left.1 == right.1 ? left.0.date > right.0.date : left.1 > right.1
            }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Ranking

    /// Best evidence first, with both ends of the timeline kept.
    ///
    /// Ranking purely by recency answers "what is the latest" and silently
    /// breaks "when did this start", which is the shape of most questions
    /// worth asking an email archive. So the oldest match is carried into
    /// the result even when the score would have dropped it.
    private func rank(_ pool: [Message], against hypotheses: [String], limit: Int) -> [Message] {
        guard !pool.isEmpty else { return [] }

        let terms = Set(hypotheses.flatMap { Highlight.terms(in: $0) }.map { $0.lowercased() })

        let scored = pool.map { message -> (Message, Int) in
            let subject = message.subject.lowercased()
            let who = "\(message.sender.name) \(message.sender.address)".lowercased()
            var score = 0
            for term in terms {
                if subject.contains(term) { score += 4 }
                if who.contains(term) { score += 3 }
                if message.body.lowercased().contains(term) { score += 1 }
            }
            return (message, score)
        }

        var ordered = scored
            .sorted { left, right in
                left.1 == right.1 ? left.0.date > right.0.date : left.1 > right.1
            }
            .map(\.0)

        // The oldest thing that matched at all, wherever it landed.
        if let oldest = pool.min(by: { $0.date < $1.date }),
           let position = ordered.firstIndex(where: { $0.id == oldest.id }),
           position >= limit {
            ordered.remove(at: position)
            ordered.insert(oldest, at: max(0, limit - 1))
        }

        return Array(ordered.prefix(limit))
    }
}
