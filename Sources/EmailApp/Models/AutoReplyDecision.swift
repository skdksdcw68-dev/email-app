import Foundation

/// What Maily decided to do about one incoming message, and why.
///
/// Every message Auto-Reply looks at produces one of these, including the
/// ones it walks straight past. That is deliberate: the question somebody
/// will actually ask is "why didn't it answer this?", and an app that only
/// records its successes cannot answer it.
///
/// The reason is written for a person to read, not a code. It goes in the
/// log, and it is the thing that earns the right to eventually let this send
/// on its own.
struct AutoReplyDecision: Identifiable, Codable, Equatable {

    enum Outcome: String, Codable {
        /// Written, waiting for them. What draft mode always produces.
        case drafted
        /// Sent by Maily. Only reachable in send mode, and only once the
        /// verification layer exists.
        case sent
        /// Inside their permissions but not confident enough, so it went the
        /// way they chose under "when unsure".
        case escalated
        /// Not eligible at all. A newsletter, a boundary, a machine.
        case skipped
        /// The model or the network let it down. Retried on a later pass.
        case failed
    }

    var id = UUID()
    var messageID: String
    var threadID: String?
    /// Who wrote in, for the log's row.
    var from: String
    var subject: String
    var outcome: Outcome
    /// One sentence, readable, saying why. Never a code.
    var reason: String
    /// The reply itself, when there is one to look at.
    var reply: String?
    /// Which of their approved facts it leaned on, from the model.
    var evidence: [String] = []
    /// What it deliberately did not answer. The half that builds trust.
    var withheld: [String] = []
    var decidedAt = Date.now

    /// Still waiting on the person: written, not yet sent or thrown away.
    var isWaiting: Bool { outcome == .drafted }

    var symbol: String {
        switch outcome {
        case .drafted: "square.and.pencil"
        case .sent: "paperplane.fill"
        case .escalated: "hand.raised.fill"
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    var outcomeTitle: String {
        switch outcome {
        case .drafted: "Written for you"
        case .sent: "Sent"
        case .escalated: "Brought to you"
        case .skipped: "Left alone"
        case .failed: "Couldn't write it"
        }
    }
}

/// Whether a message is Auto-Reply's business at all, worked out on the
/// device before a single token is spent.
///
/// Everything here is cheap and local. The expensive judgement -- what the
/// message actually asks, whether the approved facts cover it -- happens
/// afterwards and only for what survives this. Most mail does not.
enum AutoReplyEligibility {

    enum Verdict: Equatable {
        case eligible
        case ineligible(String)

        var isEligible: Bool { self == .eligible }
        var reason: String? {
            if case .ineligible(let why) = self { return why }
            return nil
        }
    }

    /// Addresses nothing should ever answer. Replying to any of these is how
    /// one setup mistake becomes forty messages to a stranger.
    private static let machineMarkers = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
        "mailer-daemon", "postmaster", "bounce", "notifications@", "notification@",
        "automated", "auto-reply", "autoreply", "support@zendesk", "mailchimp",
    ]

    /// Headers whose mere presence means leave it alone.
    ///
    /// `auto-submitted` is deliberately not here: it is the one header with a
    /// value that matters. RFC 3834 has ordinary mail from a person carry
    /// `Auto-Submitted: no`, so treating its presence as a machine would make
    /// every well-behaved mail client look like a robot.
    private static let machineHeaders = [
        "x-auto-response-suppress", "list-id", "list-unsubscribe",
        "precedence", "x-autoreply", "x-autorespond",
    ]

    /// The one call the runtime makes before spending anything.
    ///
    /// `alreadyHandled` is the set of message ids Auto-Reply has already
    /// decided about, and `repliedThreads` the threads that already have a
    /// reply from this person -- either one means leaving it alone.
    static func check(
        _ message: Message,
        config: AutoReplyConfig,
        myAddress: String,
        headers: [String: String] = [:],
        alreadyHandled: Set<String>,
        repliedThreads: Set<String>,
        now: Date = .now
    ) -> Verdict {
        guard config.isRunning else {
            return .ineligible("Auto-Reply is off.")
        }
        guard let remoteID = message.remoteID else {
            return .ineligible("This message hasn't finished downloading.")
        }
        guard !alreadyHandled.contains(remoteID) else {
            return .ineligible("Already looked at this one.")
        }
        guard message.mailbox == .inbox else {
            return .ineligible("Not in the inbox.")
        }

        let mine = myAddress.lowercased()
        guard message.sender.address.lowercased() != mine else {
            return .ineligible("You wrote this.")
        }

        // A thread this person has already answered themselves is finished
        // as far as Auto-Reply is concerned.
        if let thread = message.threadID, repliedThreads.contains(thread) {
            return .ineligible("You've already replied in this thread.")
        }

        // Machines. Checked before anything else costs money, and checked
        // both ways round: what the headers say, and what the address says.
        let lowered = headers.reduce(into: [String: String]()) { out, pair in
            out[pair.key.lowercased()] = pair.value.lowercased()
        }
        if let submitted = lowered["auto-submitted"], submitted != "no" {
            return .ineligible("Sent automatically by a machine.")
        }
        for header in machineHeaders where lowered[header] != nil {
            return .ineligible("This is a mailing list or an automated sender.")
        }
        let address = message.sender.address.lowercased()
        if machineMarkers.contains(where: address.contains) {
            return .ineligible("This address doesn't take replies.")
        }

        // What the classifier already worked out, for free, on arrival.
        if message.tags.contains(.newsletter) || message.tags.contains(.promotion) {
            return .ineligible("This is a newsletter or a promotion.")
        }

        // Old mail is not a conversation any more. Answering a three week
        // old message as though it just arrived is worse than not answering.
        let age = Calendar.current.dateComponents([.day], from: message.date, to: now).day ?? 0
        if age > staleAfterDays {
            return .ineligible("This is more than \(staleAfterDays) days old.")
        }

        return .eligible
    }

    /// After this, replying reads as strange rather than helpful.
    static let staleAfterDays = 7
}
