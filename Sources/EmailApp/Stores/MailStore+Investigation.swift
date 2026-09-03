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
/// So the model says what it needs, in one of two shapes, and this runs it:
///
/// - **Wording.** Several hypotheses about what the evidence would say. Two
///   layers, cheap first: the mail already on the phone, then Gmail's index,
///   which reaches back years. One request per hypothesis, exact words, and
///   only while there is still not enough. Everything is ranked together.
/// - **Earliest.** The oldest mail matching each query. Gmail hands back the
///   newest first, so a search for "when did I join" finds the newest eight
///   notifications and never the welcome underneath years of them. This walks
///   back to the start of the account instead. It is the difference between
///   Upwork, which does not write often and so was findable, and LinkedIn,
///   which writes every day and so was not.
///
/// Neither layer widens a query behind the model's back any more. A guess at
/// "welcome upwork" that fell back to "welcome" OR "upwork" returned the
/// newest eight emails containing "welcome" from anyone, and those were shown
/// under the answer as if they were results. If the words are wrong, the
/// model has another look and can choose different words; that is what the
/// looks are for.
extension MailStore {

    /// What a round of looking turned up, and what it did to get there.
    struct Investigation {
        /// Best first. For an earliest request, oldest first.
        var found: [Message] = []
        /// One per thing actually attempted, counted from its own results.
        var steps: [TaskStep] = []
        /// The query that produced the results, for the caption.
        var answered: String?

        var isEmpty: Bool { found.isEmpty }
    }

    /// Runs the model's request and returns the evidence.
    func investigate(_ request: SearchRequest, limit: Int = 12) async -> Investigation {
        switch request.kind {
        case .wording: await matching(request.queries, limit: limit)
        case .earliest: await earliest(request.queries)
        // Opening a message is not an investigation: the app is already
        // holding it, and the chat handles it without asking Gmail anything.
        // Reaching here would mean a caller skipped `kind.needsGmail`.
        case .opening: Investigation()
        }
    }

    // MARK: - Wording

    private func matching(_ hypotheses: [String], limit: Int) async -> Investigation {
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

        // Layer two: the account. Years deeper than the phone.
        guard isConnected, let token = try? await accessToken() else {
            report.found = rank(pool, against: hypotheses, limit: limit)
            return report
        }

        for hypothesis in hypotheses {
            // Enough evidence already, and every further request costs. The
            // first hypothesis always runs: the phone holding a match is not
            // proof the account does not hold an older one.
            if pool.count >= limit, hypothesis != hypotheses[0] { break }

            guard let page = try? await GmailService.fetchInbox(
                accessToken: token, limit: limit, query: hypothesis, label: nil
            ) else {
                report.steps.append(.unreachable(hypothesis))
                continue
            }

            report.steps.append(.searched(hypothesis, found: page.messages))
            guard !page.messages.isEmpty else { continue }

            absorb(page.messages)
            for message in page.messages where seen.insert(message.remoteID ?? message.id.uuidString).inserted {
                pool.append(message)
            }
            if report.answered == nil { report.answered = hypothesis }
        }

        report.found = rank(pool, against: hypotheses, limit: limit)
        return report
    }

    /// The mail on this phone that says all of it.
    ///
    /// Every term has to be there, the way Gmail treats the same query. The
    /// first version scored any term, which meant "upwork welcome" matched
    /// every email with "welcome" in it, and iCloud, Stripe and Google were
    /// read out as evidence about Upwork.
    ///
    /// Where a word lands still decides what the match is worth. A name in
    /// the subject or the sender is what a person remembers a message by; the
    /// same words in the body of a newsletter are nearly nothing.
    func localMatches(for query: String, limit: Int) -> [Message] {
        let terms = Highlight.terms(in: query).map { $0.lowercased() }
        guard !terms.isEmpty else { return [] }

        let scored = messages.compactMap { message -> (Message, Int)? in
            let subject = message.subject.lowercased()
            let who = "\(message.sender.name) \(message.sender.address)".lowercased()
            let body = message.body.lowercased()

            var score = 0
            for word in terms {
                let inSubject = subject.contains(word)
                let inWho = who.contains(word)
                let inBody = body.contains(word)
                guard inSubject || inWho || inBody else { return nil }
                if inSubject { score += 4 }
                if inWho { score += 4 }
                if inBody { score += 1 }
            }
            return (message, score)
        }

        return scored
            .sorted { left, right in
                left.1 == right.1 ? left.0.date > right.0.date : left.1 > right.1
            }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Earliest

    /// How far back the walk will go for one query. Ids only, five hundred a
    /// request, so this is twenty requests at the very worst and usually two
    /// or three. Past it the oldest found is reported as such, not as the
    /// oldest there is.
    static let earliestCeiling = 10_000

    /// How many of the oldest to bring back per query. The very oldest is
    /// sometimes a verification code and the welcome is the one after it.
    static let earliestSample = 3

    private func earliest(_ queries: [String]) async -> Investigation {
        var report = Investigation()
        guard isConnected, let token = try? await accessToken() else {
            return report
        }

        var seen = Set<String>()
        for query in queries {
            guard let ids = try? await GmailService.allMessageIDs(
                matching: query, accessToken: token, ceiling: Self.earliestCeiling
            ) else {
                report.steps.append(.unreachable(query))
                continue
            }

            // Newest first is how they come, so the end of the list is the
            // beginning of the story.
            let oldestIDs = Array(ids.suffix(Self.earliestSample))
            let fetched = (try? await GmailService.messages(ids: oldestIDs, accessToken: token)) ?? []
            let oldestFirst = fetched.sorted { $0.date < $1.date }

            report.steps.append(.wentBack(
                query, found: oldestFirst, reachedStart: ids.count < Self.earliestCeiling
            ))
            guard !oldestFirst.isEmpty else { continue }

            absorb(oldestFirst)
            for message in oldestFirst where seen.insert(message.remoteID ?? message.id.uuidString).inserted {
                report.found.append(message)
            }
            if report.answered == nil { report.answered = query }
        }

        return report
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
