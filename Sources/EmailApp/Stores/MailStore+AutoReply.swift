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

            // The reply read back against what they approved, on the
            // device. The model was told what it may say; this is the part
            // that does not take its word for it.
            let verified = AutoReplyVerification.check(
                reply: result.reply,
                approved: config.business.filled.map(\.value).joined(separator: "\n"),
                boundaries: AutoReplyConfig.Boundary.allCases
                    .filter(config.mustAsk.contains)
                    .map(\.title),
                confidence: result.confidence,
                floor: Self.autoReplyConfidenceFloor
            )

            guard verified.isClear else {
                queue.record(decision(
                    for: message,
                    outcome: .escalated,
                    reason: verified.problems.first ?? "Maily wasn't sure enough about this one.",
                    reply: result.reply,
                    evidence: result.evidence,
                    withheld: result.withheld + verified.problems,
                    verification: verified
                ))
                Analytics.record(.autoReplyHeldBack, ["problems": .int(verified.problems.count)])
                return
            }

            var written = decision(
                for: message,
                outcome: .drafted,
                reason: result.reason.isEmpty ? "Answered from what you approved." : result.reason,
                reply: result.reply,
                evidence: result.evidence,
                withheld: result.withheld,
                verification: verified
            )

            Analytics.record(.autoReplyDrafted, [
                "category": .string(result.category),
                "confidence": .int(Int(result.confidence * 100)),
                "withheld": .int(result.withheld.count),
            ])

            // The only place in the app where something leaves without a
            // person touching it. Everything above had to pass first, and
            // everything below is a reason not to.
            guard let refusal = reasonNotToSend(
                result: result, config: config, message: message, queue: queue
            ) else {
                queue.record(written)
                do {
                    try await send(
                        subject: replySubject(for: message),
                        to: message.sender.address,
                        body: result.reply,
                        replyingTo: message
                    )
                    markReplied(message.id)
                    queue.markAutoSent(written.id)
                    await AutoReplyNotice.post(to: message.sender.name, subject: message.subject)
                    Analytics.record(.autoReplySent, ["edited": .bool(false), "auto": .bool(true)])
                } catch {
                    // It did not go. It stays a draft, which is the safe
                    // half of the two outcomes.
                    queue.record(written)
                }
                return
            }

            // Held as a draft, with the reason it was not sent, so the log
            // says why rather than leaving them to guess.
            if config.mode == .send {
                written.reason += " Not sent: \(refusal)"
            }
            queue.record(written)
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
        withheld: [String] = [],
        verification: AutoReplyVerification? = nil
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
            withheld: withheld,
            verification: verification
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

        // Whether they changed it before sending is the single most useful
        // thing to know about how good these are, and it has to be read
        // before the queue is updated. The reply itself never leaves the
        // phone; only whether it was touched.
        let asWritten = queue.log.first { $0.messageID == decision.messageID }?.reply

        markReplied(original.id)
        queue.markSent(decision.id)
        Analytics.record(.autoReplySent, ["edited": .bool(asWritten != reply)])
    }
}

extension MailStore {

    /// Why this reply must not go on its own, or nil when nothing stands in
    /// the way.
    ///
    /// Written as a list of refusals rather than a list of permissions, on
    /// purpose. A permission check that gains a bug lets something through;
    /// a refusal check that gains a bug holds something back. Only one of
    /// those failure modes emails a stranger.
    func reasonNotToSend(
        result: AIService.AutoReplyResult,
        config: AutoReplyConfig,
        message: Message,
        queue: AutoReplyQueue,
        now: Date = .now
    ) -> String? {
        guard config.mode == .send else {
            return "Auto-Reply is set to write, not send."
        }
        guard config.isRunning else {
            return "Auto-Reply isn't running."
        }
        // A higher bar than a draft. Something a person is going to read
        // before it goes can afford to be a good guess; something that
        // leaves on its own cannot.
        guard result.confidence >= Self.autoSendConfidenceFloor else {
            return "Maily was only \(Int(result.confidence * 100))% sure."
        }
        // Anything it could not fully answer is a conversation, not a
        // transaction, and conversations are the person's.
        guard result.withheld.isEmpty else {
            return "Part of it needed you."
        }
        guard !queue.hasAutoSent(inThread: message.threadID) else {
            return "Maily has already answered in this conversation."
        }
        let recent = queue.autoSentInLastHour(now: now)
        guard recent < Self.autoSendPerHour else {
            return "That's \(Self.autoSendPerHour) sent in an hour already."
        }
        return nil
    }

    /// The bar for leaving without a person. Deliberately well above the
    /// bar for writing a draft.
    static let autoSendConfidenceFloor = 0.9

    /// The most Maily will send by itself in an hour. A bad setup should
    /// cost somebody a handful of awkward emails, not a mailing list's
    /// worth -- and anybody legitimately receiving more than this an hour
    /// should be reading them.
    static let autoSendPerHour = 5

    func replySubject(for message: Message) -> String {
        message.subject.lowercased().hasPrefix("re:")
            ? message.subject
            : "Re: \(message.subject)"
    }
}
