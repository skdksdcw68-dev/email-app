import XCTest
@testable import EmailApp

/// The guards on the one thing in this app that happens without a person.
///
/// Written as refusals rather than permissions on purpose: a permission check
/// that gains a bug lets something out, a refusal check that gains a bug
/// holds something back, and only one of those emails a stranger.
@MainActor
final class AutoSendGuardTests: XCTestCase {

    private var mail: MailStore!
    private var queue: AutoReplyQueue!
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appending(path: "arq-\(UUID().uuidString).json")
        queue = AutoReplyQueue(fileURL: url)
        mail = MailStore(
            account: MailAccount(provider: .gmail, address: "abel@example.com", displayName: "Abel"), registry: .throwaway(),
            facts: FactStore(fileURL: FileManager.default.temporaryDirectory
                .appending(path: "f-\(UUID().uuidString).json"))
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func sending() -> AutoReplyConfig {
        var config = AutoReplyConfig()
        config.persona = .freelancer
        config.allowed = [.pricing]
        config.isSetUp = true
        config.isOn = true
        config.knowledgeConfirmed = true
        config.mode = .send
        return config
    }

    private func result(confidence: Double = 0.97, withheld: [String] = []) -> AIService.AutoReplyResult {
        let held = withheld.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"handled": true, "reply": "Hi.", "reason": "ok", "category": "Pricing questions",
         "evidence": [], "withheld": [\(held)], "confidence": \(confidence)}
        """
        return try! JSONDecoder().decode(AIService.AutoReplyResult.self, from: Data(json.utf8))
    }

    private func message(thread: String? = "t1") -> Message {
        var message = Message(
            sender: Contact(name: "Sara", address: "sara@x.com"),
            recipients: [],
            subject: "Pricing",
            body: "What do you charge?",
            date: .now
        )
        message.remoteID = "m1"
        message.threadID = thread
        return message
    }

    private func reason(
        _ result: AIService.AutoReplyResult,
        config: AutoReplyConfig? = nil,
        thread: String? = "t1"
    ) -> String? {
        mail.reasonNotToSend(
            result: result,
            config: config ?? sending(),
            message: message(thread: thread),
            queue: queue
        )
    }

    private func autoSent(_ id: String, thread: String, minutesAgo: Int = 0) -> AutoReplyDecision {
        var decision = AutoReplyDecision(
            messageID: id, threadID: thread, from: "Someone", subject: "A question",
            outcome: .sent, reason: "Maily sent this for you."
        )
        decision.wasAutoSent = true
        decision.decidedAt = Date.now.addingTimeInterval(Double(-minutesAgo * 60))
        return decision
    }

    // MARK: - The one case that is allowed to send

    func testAConfidentCompleteReplyInSendModeGoes() {
        XCTAssertNil(reason(result()))
    }

    // MARK: - Everything that stops it

    func testDraftModeNeverSends() {
        var config = sending()
        config.mode = .draft
        XCTAssertNotNil(reason(result(), config: config))
    }

    func testSwitchedOffNeverSends() {
        var config = sending()
        config.isOn = false
        XCTAssertNotNil(reason(result(), config: config))
    }

    func testAnUnconfirmedSetupNeverSends() {
        var config = sending()
        config.knowledgeConfirmed = false
        XCTAssertNotNil(reason(result(), config: config))
    }

    func testTheBarForSendingIsHigherThanForDrafting() {
        // 0.8 is good enough to write something a person will read. It is
        // not good enough to leave on its own.
        XCTAssertGreaterThan(MailStore.autoSendConfidenceFloor, MailStore.autoReplyConfidenceFloor)
        XCTAssertNotNil(reason(result(confidence: 0.8)))
        XCTAssertNil(reason(result(confidence: 0.95)))
    }

    func testAnythingItCouldNotFullyAnswerStaysWithThePerson() {
        // A half-answered message is a conversation, and conversations are
        // the person's job.
        XCTAssertNotNil(reason(result(withheld: ["The delivery date"])))
    }

    func testItNeverSendsTwiceInOneConversation() {
        queue.record(autoSent("old", thread: "t1"))

        XCTAssertNotNil(reason(result(), thread: "t1"))
        XCTAssertNil(reason(result(), thread: "t2"), "a different conversation is fine")
    }

    func testTheHourlyLimitStopsARunawaySetup() {
        for index in 0..<MailStore.autoSendPerHour {
            queue.record(autoSent("m\(index)", thread: "t\(index)"))
        }

        XCTAssertEqual(queue.autoSentInLastHour(), MailStore.autoSendPerHour)
        XCTAssertNotNil(reason(result(), thread: "new"))
    }

    func testRepliesThePersonSentThemselvesDoNotCountAgainstTheLimit() {
        // Somebody answering their own mail twenty times is somebody using
        // the app, not a runaway.
        for index in 0..<20 {
            queue.record(AutoReplyDecision(
                messageID: "m\(index)", threadID: "t\(index)", from: "Someone",
                subject: "A question", outcome: .sent, reason: "You sent this."
            ))
        }
        XCTAssertEqual(queue.autoSentInLastHour(), 0)
        XCTAssertNil(reason(result(), thread: "new"))
    }

    func testOldSendsFallOutOfTheHourlyWindow() {
        queue.record(autoSent("old", thread: "t9", minutesAgo: 120))
        XCTAssertEqual(queue.autoSentInLastHour(), 0)
    }

    // MARK: - The way out

    func testStoppingEverythingTurnsItOffAndPutsTheModeBack() {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "ar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let store = AutoReplyStore(fileURL: storeURL)
        store.complete(sending())
        store.setMode(.send)

        store.stopEverything()

        XCTAssertFalse(store.config.isOn)
        XCTAssertEqual(store.config.mode, .draft)
        // The setup survives. Panicking about one bad reply should not cost
        // somebody the afternoon they spent teaching Maily their business.
        XCTAssertTrue(store.config.isSetUp)
        XCTAssertEqual(store.config.persona, .freelancer)
    }

    func testEveryRefusalIsASentence() {
        var draftMode = sending()
        draftMode.mode = .draft
        let refusals = [
            reason(result(), config: draftMode),
            reason(result(confidence: 0.3)),
            reason(result(withheld: ["Something"])),
        ]
        for refusal in refusals {
            XCTAssertNotNil(refusal)
            XCTAssertTrue(refusal!.hasSuffix("."), "reasons are sentences: \(refusal!)")
        }
    }
}
