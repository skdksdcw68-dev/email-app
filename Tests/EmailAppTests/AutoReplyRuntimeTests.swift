import XCTest
@testable import EmailApp

/// The gate that runs before anything is spent, and before anything is
/// written. Everything here is a way for Auto-Reply to answer something it
/// should have left alone, which is the failure that costs somebody a
/// customer -- or spams a stranger forty times.
@MainActor
final class AutoReplyRuntimeTests: XCTestCase {

    private let me = "abel@example.com"

    private func running() -> AutoReplyConfig {
        var config = AutoReplyConfig()
        config.persona = .freelancer
        config.allowed = [.pricing, .general]
        config.isSetUp = true
        config.isOn = true
        config.knowledgeConfirmed = true
        return config
    }

    private func message(
        from: String = "sara@x.com",
        thread: String? = "t1",
        daysAgo: Int = 0,
        mailbox: Mailbox = .inbox,
        tags: Set<AITag> = [],
        remoteID: String = "m1"
    ) -> Message {
        var message = Message(
            sender: Contact(name: "Sara", address: from),
            recipients: [Contact(name: "Abel", address: me)],
            subject: "A question",
            body: "Do you have availability next month?",
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            mailbox: mailbox,
            tags: tags
        )
        message.remoteID = remoteID
        message.threadID = thread
        return message
    }

    private func check(
        _ message: Message,
        config: AutoReplyConfig? = nil,
        headers: [String: String] = [:],
        handled: Set<String> = [],
        replied: [String: Date] = [:]
    ) -> AutoReplyEligibility.Verdict {
        AutoReplyEligibility.check(
            message,
            config: config ?? running(),
            myAddress: me,
            headers: headers,
            alreadyHandled: handled,
            myLatestReply: replied
        )
    }

    // MARK: - The happy path, so the rest means something

    func testAnOrdinaryQuestionFromAPersonIsEligible() {
        XCTAssertTrue(check(message()).isEligible)
    }

    // MARK: - Never running when it shouldn't be

    func testNothingIsEligibleWhileAutoReplyIsOff() {
        var config = running()
        config.isOn = false
        XCTAssertFalse(check(message(), config: config).isEligible)
    }

    func testNothingIsEligibleBeforeTheFactsAreConfirmed() {
        var config = running()
        config.knowledgeConfirmed = false
        XCTAssertFalse(check(message(), config: config).isEligible)
    }

    func testAHalfFinishedSetupNeverRuns() {
        var config = running()
        config.isSetUp = false
        XCTAssertFalse(check(message(), config: config).isEligible)
    }

    // MARK: - Loops and machines

    func testAutoSubmittedMailIsNeverAnswered() {
        // RFC 3834 exists so automatic responders can recognise each other.
        // Two of them that cannot is an infinite loop through somebody's
        // mailbox.
        let verdict = check(message(), headers: ["Auto-Submitted": "auto-replied"])
        XCTAssertFalse(verdict.isEligible)
        XCTAssertEqual(verdict.reason, "Sent automatically by a machine.")
    }

    func testAutoSubmittedNoIsAHumanAndStillEligible() {
        // "no" is what a person's own mail client sets. It must not be read
        // as a machine.
        XCTAssertTrue(check(message(), headers: ["Auto-Submitted": "no"]).isEligible)
    }

    func testMailingListsAreNeverAnswered() {
        for header in ["List-Id", "List-Unsubscribe", "Precedence", "X-Autoreply"] {
            XCTAssertFalse(check(message(), headers: [header: "whatever"]).isEligible, header)
        }
    }

    func testAddressesThatDoNotTakeRepliesAreLeftAlone() {
        for address in ["noreply@stripe.com", "no-reply@x.com", "mailer-daemon@x.com",
                        "bounce@x.com", "notifications@github.com", "donotreply@bank.com"] {
            XCTAssertFalse(check(message(from: address)).isEligible, address)
        }
    }

    func testNewslettersAndPromotionsAreLeftAlone() {
        XCTAssertFalse(check(message(tags: [.newsletter])).isEligible)
        XCTAssertFalse(check(message(tags: [.promotion])).isEligible)
    }

    // MARK: - Never answering twice, never talking to yourself

    func testYourOwnMailIsNeverAnswered() {
        XCTAssertFalse(check(message(from: me)).isEligible)
    }

    func testAMessageAlreadyDecidedAboutIsNotReconsidered() {
        XCTAssertFalse(check(message(remoteID: "m1"), handled: ["m1"]).isEligible)
    }

    func testAThreadYouPickedUpAfterwardsIsLeftAlone() {
        let incoming = message(thread: "t9", daysAgo: 2)
        let verdict = check(incoming, replied: ["t9": .now])
        XCTAssertFalse(verdict.isEligible)
        XCTAssertEqual(verdict.reason, "You've already answered this yourself.")
    }

    func testSomethingYouWroteBeforeItDoesNotBlockTheReply() {
        // The old rule checked only whether the thread contained anything
        // from them, so a conversation answered in March was dead to
        // Auto-Reply for ever -- and a mail they had just sent themselves
        // blocked its own reply.
        let incoming = message(thread: "t9", daysAgo: 0)
        let longAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        XCTAssertTrue(check(incoming, replied: ["t9": longAgo]).isEligible)
    }

    // MARK: - Scope

    func testOnlyInboxMailIsConsidered() {
        for mailbox in [Mailbox.sent, .archive, .trash, .drafts] {
            XCTAssertFalse(check(message(mailbox: mailbox)).isEligible, "\(mailbox)")
        }
    }

    func testOldMailIsNotAConversationAnyMore() {
        XCTAssertTrue(check(message(daysAgo: AutoReplyEligibility.staleAfterDays - 1)).isEligible)
        XCTAssertFalse(check(message(daysAgo: AutoReplyEligibility.staleAfterDays + 1)).isEligible)
    }

    func testAMessageStillDownloadingIsNotAnswered() {
        var partial = message()
        partial.remoteID = nil
        XCTAssertFalse(check(partial).isEligible)
    }

    // MARK: - Every refusal explains itself

    func testEveryRefusalCarriesAReadableReason() {
        // The question people ask is "why didn't it answer this?", and a
        // code is not an answer.
        let refusals = [
            check(message(from: me)),
            check(message(tags: [.newsletter])),
            check(message(mailbox: .archive)),
            check(message(daysAgo: 30)),
            check(message(), headers: ["List-Id": "x"]),
        ]
        for verdict in refusals {
            let reason = verdict.reason ?? ""
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(reason.hasSuffix("."), "reasons are sentences: \(reason)")
        }
    }

    // MARK: - The queue

    func testADraftWaitsUntilItIsSentOrBinned() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = AutoReplyQueue(fileURL: url)
        let decision = AutoReplyDecision(
            messageID: "m1", threadID: "t1", from: "Sara", subject: "A question",
            outcome: .drafted, reason: "Answered from what you approved.", reply: "Hi Sara,"
        )
        queue.record(decision)

        XCTAssertEqual(queue.waiting.count, 1)
        XCTAssertTrue(queue.hasDecided("m1"))

        queue.markSent(decision.id)
        XCTAssertTrue(queue.waiting.isEmpty)
        XCTAssertEqual(queue.log.count, 1, "sending it does not erase the record")
    }

    func testBinningKeepsTheRecordButDropsTheReply() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = AutoReplyQueue(fileURL: url)
        let decision = AutoReplyDecision(
            messageID: "m1", threadID: nil, from: "Sara", subject: "A question",
            outcome: .drafted, reason: "Answered.", reply: "Hi Sara,"
        )
        queue.record(decision)
        queue.discard(decision.id)

        XCTAssertTrue(queue.waiting.isEmpty)
        XCTAssertEqual(queue.log.count, 1)
        XCTAssertNil(queue.log[0].reply)
    }

    func testSkipsAreLoggedSoTheAppCanSayWhyItDidNothing() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = AutoReplyQueue(fileURL: url)
        queue.record(AutoReplyDecision(
            messageID: "m1", threadID: nil, from: "Substack", subject: "This week",
            outcome: .skipped, reason: "This is a newsletter or a promotion."
        ))

        XCTAssertTrue(queue.waiting.isEmpty)
        XCTAssertEqual(queue.log.count, 1)
        XCTAssertEqual(queue.log[0].reason, "This is a newsletter or a promotion.")
    }

    func testAFailureCanBeTriedAgain() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = AutoReplyQueue(fileURL: url)
        queue.record(AutoReplyDecision(
            messageID: "m1", threadID: nil, from: "Sara", subject: "A question",
            outcome: .failed, reason: "Couldn't reach the service."
        ))
        XCTAssertTrue(queue.hasDecided("m1"))

        queue.allowRetry("m1")
        XCTAssertFalse(queue.hasDecided("m1"), "the service being down is not a decision about the message")
    }

    func testTheQueueSurvivesARelaunchAndGoesWithTheMailbox() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = AutoReplyQueue(fileURL: url)
        queue.record(AutoReplyDecision(
            messageID: "m1", threadID: nil, from: "Sara", subject: "A question",
            outcome: .drafted, reason: "Answered.", reply: "Hi Sara,"
        ))

        XCTAssertEqual(AutoReplyQueue(fileURL: url).waiting.count, 1)

        // A drafted reply quotes an email, so it is mail content and it goes
        // when the mailbox goes.
        queue.clearAll()
        XCTAssertTrue(AutoReplyQueue(fileURL: url).log.isEmpty)
    }
}
