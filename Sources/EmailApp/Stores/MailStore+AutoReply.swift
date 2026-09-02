import Foundation

/// The Auto-Reply runtime: the pass that looks at new mail and writes the
/// replies somebody authorised Maily to write.
///
/// The pipeline, in the order it runs, and every stage may end it:
///
///   incoming message
///     -> eligible at all?          (device, free -- most mail stops here)
///     -> allowed category, boundaries, facts, rules   (the model)
///     -> confident enough?         (device)
///     -> drafted / escalated / skipped, and logged either way
///
/// Fail closed at every step. A stage that cannot answer produces a decision
/// saying so, never a reply. And in draft mode -- the only mode that exists
/// today -- the end of a successful run is a reply sitting in a queue with
/// somebody's thumb over the send button, which is the point.
extension MailStore {

    /// Looks at whatever has arrived since the last pass.
    ///
    /// Called after mail lands, alongside the classifier. Deliberately small:
    /// a handful per pass, newest first. Auto-Reply working through a
    /// three-month backlog on the day it is switched on would be somebody
    /// waking up to two hundred drafts about conversations that ended in
    /// June.
    func runAutoReply(
        config: AutoReplyConfig,
        briefing: String,
        queue: AutoReplyQueue,
        limit: Int = 5
    ) async {
        guard config.isRunning, isConnected, let account else { return }
        guard !queue.isChecking else { return }
        queue.beginCheck()
        defer { queue.endCheck() }

        // Fresh mail first. A pass that looks at what was already on the
        // phone will keep reporting that nothing arrived, which is exactly
        // what it looks like when this is broken.
        await catchUp()


        // The last thing this person wrote in each conversation, so
        // Auto-Reply never writes into one they have picked up since. The
        // date is the whole point: anything they wrote *before* the message
        // being considered is history, not an answer to it.
        let mine = account.email.lowercased()
        var myLatestReply: [String: Date] = [:]
        for message in messages where message.mailbox == .sent
            || message.sender.address.lowercased() == mine {
            guard let thread = message.threadID else { continue }
            if let known = myLatestReply[thread], known >= message.date { continue }
            myLatestReply[thread] = message.date
        }

        let candidates = messages(in: .inbox)
            .filter { message in
                guard let remoteID = message.remoteID else { return false }
                return !queue.hasDecided(remoteID)
            }
            .prefix(Self.autoReplyScanLimit)

        var written = 0
        for message in candidates where written < limit {
            guard let remoteID = message.remoteID else { continue }

            let verdict = AutoReplyEligibility.check(
                message,
                config: config,
                myAddress: account.email,
                headers: [:],
                alreadyHandled: queue.handled,
                myLatestReply: myLatestReply
            )

            guard verdict.isEligible else {
                // Logged rather than dropped. "Why didn't it answer this?"
                // is the question people actually ask, and it deserves an
                // answer that costs nothing to keep.
                queue.record(
                    decision(for: message, outcome: .skipped, reason: verdict.reason ?? "Not eligible.")
                )
                continue
            }

            written += 1
            await write(for: message, remoteID: remoteID, briefing: briefing, config: config, queue: queue)
        }
    }

    /// How far down the inbox one pass will look before giving up. The cheap
    /// checks run on all of these; only what survives costs anything.
    static let autoReplyScanLimit = 60

    private func write(
        for message: Message,
        remoteID: String,
        briefing: String,
        config: AutoReplyConfig,
        queue: AutoReplyQueue
    ) async {
        let thread = messages
            .filter { $0.threadID != nil && $0.threadID == message.threadID && $0.id != message.id }
            .sorted { $0.date < $1.date }
            .suffix(3)
            .map { "\($0.sender.name.isEmpty ? $0.sender.address : $0.sender.name) wrote on \($0.fullDate):\n\($0.body.prefix(400))" }
            .joined(separator: "\n\n")

        do {
            let result = try await AIService.autoReply(
                message: message,
                briefing: briefing,
                thread: thread
            )

            guard result.handled else {
                // The model declining is a real answer, not a failure. It
                // goes the way they chose for when Maily is unsure.
                queue.record(decision(
                    for: message,
                    outcome: .escalated,
                    reason: result.reason.isEmpty ? "Maily wasn't sure enough to answer this." : result.reason,
                    withheld: result.withheld
                ))
                return
            }

            guard result.confidence >= Self.autoReplyConfidenceFloor else {
                queue.record(decision(
                    for: message,
                    outcome: .escalated,
                    reason: "Maily could answer this but wasn't confident enough, so it's yours.",
                    reply: result.reply,
                    evidence: result.evidence,
                    withheld: result.withheld
                ))
                return
            }

            queue.record(decision(
                for: message,
                outcome: .drafted,
                reason: result.reason.isEmpty ? "Answered from what you approved." : result.reason,
                reply: result.reply,
                evidence: result.evidence,
                withheld: result.withheld
            ))

            Analytics.record(.autoReplyDrafted, [
                "category": .string(result.category),
                "confidence": .int(Int(result.confidence * 100)),
                "withheld": .int(result.withheld.count),
            ])
        } catch {
            // Left retryable: the service being down is not a decision about
            // this message, and pretending otherwise would silently skip it
            // for good.
            queue.record(decision(
                for: message,
                outcome: .failed,
                reason: "Maily couldn't reach the writing service. It'll try again."
            ))
            queue.allowRetry(remoteID)
        }
    }

    /// Below this, a reply is a guess. It still gets written down -- so they
    /// can read it and decide -- but it is presented as something Maily
    /// brought to them rather than something it finished.
    static let autoReplyConfidenceFloor = 0.7

    private func decision(
        for message: Message,
        outcome: AutoReplyDecision.Outcome,
        reason: String,
        reply: String? = nil,
        evidence: [String] = [],
        withheld: [String] = []
    ) -> AutoReplyDecision {
        AutoReplyDecision(
            messageID: message.remoteID ?? message.id.uuidString,
            threadID: message.threadID,
            from: message.sender.name.isEmpty ? message.sender.address : message.sender.name,
            subject: message.subject,
            outcome: outcome,
            reason: reason,
            reply: reply,
            evidence: evidence,
            withheld: withheld
        )
    }

    /// Sends a reply the person approved, through the same path as any other
    /// reply they write themselves. There is no second send path, and there
    /// will not be one when auto-send arrives -- one door, one set of rules.
    func sendAutoReply(_ decision: AutoReplyDecision, queue: AutoReplyQueue) async throws {
        guard let reply = decision.reply, !reply.isEmpty else { return }
        guard let original = messages.first(where: { $0.remoteID == decision.messageID }) else { return }

        try await send(
            subject: original.subject.lowercased().hasPrefix("re:")
                ? original.subject
                : "Re: \(original.subject)",
            to: original.sender.address,
            body: reply,
            replyingTo: original
        )

        markReplied(original.id)
        queue.markSent(decision.id)
        Analytics.record(.autoReplySent, ["edited": .bool(false)])
    }
}
