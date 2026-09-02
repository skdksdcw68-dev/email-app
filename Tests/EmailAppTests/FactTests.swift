import XCTest
@testable import EmailApp

/// The second tier: what a message committed somebody to, turned around to
/// the reader's side, kept, and crossed off as the mail moves on.
@MainActor
final class FactTests: XCTestCase {

    private let me = "abel@example.com"
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "facts-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func message(
        id: String,
        thread: String = "t1",
        from: String = "sara@x.com",
        to: [String] = ["abel@example.com"],
        daysAgo: Int = 1,
        mailbox: Mailbox = .inbox
    ) -> Message {
        var message = Message(
            sender: Contact(name: from == "sara@x.com" ? "Sara Chen" : "", address: from),
            recipients: to.map { Contact(name: "", address: $0) },
            subject: "Q3 pricing",
            body: "Body",
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            mailbox: mailbox
        )
        message.remoteID = id
        message.threadID = thread
        return message
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: offset, to: .now)!)
    }

    private func iso(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    // MARK: - Turning the extraction around

    func testReceivedMailPutsTheirAsksOnMeAndTheirPromisesOnThem() {
        let extraction = Extraction(
            requests: [.init(what: "Send the revised quote.", due: "2026-09-04")],
            commitments: [.init(what: "Share the deck", due: nil)],
            questions: ["Does Thursday work?"],
            dates: [.init(what: "Board meeting", due: nil, on: "2026-09-11")]
        )
        let facts = extraction.facts(for: message(id: "m1"), myAddress: me)

        XCTAssertEqual(facts.count, 4)
        XCTAssertEqual(facts[0].kind, .request)
        XCTAssertEqual(facts[0].owedBy, .me)
        XCTAssertEqual(facts[0].text, "Send the revised quote")
        XCTAssertEqual(facts[0].due, Extraction.day("2026-09-04"))
        XCTAssertEqual(facts[1].kind, .commitment)
        XCTAssertEqual(facts[1].owedBy, .them)
        XCTAssertEqual(facts[2].kind, .question)
        XCTAssertEqual(facts[2].owedBy, .me)
        XCTAssertEqual(facts[3].kind, .date)
        XCTAssertEqual(facts[3].due, Extraction.day("2026-09-11"))
        // Every one of them is about Sara, and points back at her message.
        XCTAssertTrue(facts.allSatisfy { $0.person.address == "sara@x.com" && $0.messageID == "m1" })
    }

    func testSentMailPutsMyAsksOnThemAndMyPromisesOnMe() {
        let extraction = Extraction(
            requests: [.init(what: "Confirm the venue", due: nil)],
            commitments: [.init(what: "Send the contract Monday", due: "2026-09-07")],
            questions: ["Is the budget final?"]
        )
        let sent = message(id: "m2", from: me, to: ["sara@x.com"], mailbox: .sent)
        let facts = extraction.facts(for: sent, myAddress: me)

        XCTAssertEqual(facts.map(\.owedBy), [.them, .me, .them])
        // The other person is who I wrote to, not me.
        XCTAssertTrue(facts.allSatisfy { $0.person.address == "sara@x.com" })
    }

    func testAMessageWithoutARemoteIDYieldsNothing() {
        var local = message(id: "m3")
        local.remoteID = nil
        let facts = Extraction(requests: [.init(what: "Send it", due: nil)]).facts(for: local, myAddress: me)
        XCTAssertTrue(facts.isEmpty)
    }

    func testADateTheModelCouldNotPinToADayIsDropped() {
        let extraction = Extraction(dates: [
            .init(what: "Sometime next week", due: nil, on: "next week"),
            .init(what: "Board meeting", due: nil, on: "2026-09-11"),
        ])
        let facts = extraction.facts(for: message(id: "m4"), myAddress: me)
        XCTAssertEqual(facts.map(\.text), ["Board meeting"])
    }

    func testEachListIsCappedAtFour() {
        let many = (1...9).map { Extraction.Item(what: "Do thing number \($0)", due: nil) }
        let facts = Extraction(requests: many).facts(for: message(id: "m5"), myAddress: me)
        XCTAssertEqual(facts.count, 4)
    }

    func testTheServerMayLeaveListsOutOrWrapQuestions() throws {
        let sparse = try JSONDecoder().decode(Extraction.self, from: Data(#"{"requests":[]}"#.utf8))
        XCTAssertTrue(sparse.isEmpty)

        let wrapped = try JSONDecoder().decode(
            Extraction.self,
            from: Data(#"{"questions":[{"what":"Does Thursday work?"}]}"#.utf8)
        )
        XCTAssertEqual(wrapped.questions, ["Does Thursday work?"])
    }

    func testDayParsing() {
        XCTAssertNotNil(Extraction.day("2026-09-04"))
        XCTAssertNotNil(Extraction.day(" 2026-09-04 "))
        XCTAssertNil(Extraction.day("Friday"))
        XCTAssertNil(Extraction.day("2026-13-04"))
        XCTAssertNil(Extraction.day(""))
    }

    // MARK: - Describing

    func testDescribePointsAtTheNumberedMessageAndSaysWhoseMoveItIs() {
        let fact = Extraction(requests: [.init(what: "Send the revised quote", due: iso(day(-2)))])
            .facts(for: message(id: "m1", daysAgo: 5), myAddress: me)[0]
        let numbered = [message(id: "other"), message(id: "m1")]

        let line = FactStore.describe([fact], numbered: numbered)

        XCTAssertTrue(line.hasPrefix("- On you: Send the revised quote. Sara Chen asked on"), line)
        XCTAssertTrue(line.contains("(overdue)"), line)
        XCTAssertTrue(line.hasSuffix("[2]"), line)
    }

    func testDescribeLeavesOffTheNumberWhenTheMessageIsNotInTheList() {
        let fact = Extraction(commitments: [.init(what: "Share the deck", due: nil)])
            .facts(for: message(id: "m1"), myAddress: me)[0]
        let line = FactStore.describe([fact], numbered: [])
        XCTAssertTrue(line.hasPrefix("- On them: Sara Chen said they would share the deck"), line)
        XCTAssertFalse(line.contains("["))
    }

    func testDayPhrase() {
        XCTAssertEqual(Fact.dayPhrase(day(0)), "today")
        XCTAssertEqual(Fact.dayPhrase(day(1)), "tomorrow")
        XCTAssertEqual(Fact.dayPhrase(day(-1)), "yesterday")
        XCTAssertFalse(Fact.dayPhrase(day(5)).isEmpty)
    }

    // MARK: - Keeping

    func testRecordingAMessageTwiceReplacesRatherThanDoubles() {
        let store = FactStore(fileURL: fileURL)
        let first = Extraction(requests: [.init(what: "Send it", due: nil)])
            .facts(for: message(id: "m1"), myAddress: me)
        let second = Extraction(requests: [.init(what: "Send it", due: nil), .init(what: "Call me", due: nil)])
            .facts(for: message(id: "m1"), myAddress: me)

        store.record(first, from: "m1")
        store.record(second, from: "m1")

        XCTAssertEqual(store.facts.count, 2)
        XCTAssertTrue(store.hasExtracted("m1"))
    }

    func testAMessageThatYieldedNothingIsStillMarkedRead() {
        let store = FactStore(fileURL: fileURL)
        store.record([], from: "m1")
        XCTAssertTrue(store.hasExtracted("m1"))
        XCTAssertFalse(store.hasExtracted("m2"))
    }

    func testFactsSurviveARelaunch() {
        let store = FactStore(fileURL: fileURL)
        store.record(
            Extraction(requests: [.init(what: "Send it", due: nil)]).facts(for: message(id: "m1"), myAddress: me),
            from: "m1"
        )
        store.record([], from: "m2")

        let reloaded = FactStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.facts.map(\.text), ["Send it"])
        XCTAssertTrue(reloaded.hasExtracted("m2"))
    }

    func testDisconnectingClearsEverything() {
        let store = FactStore(fileURL: fileURL)
        store.record(
            Extraction(requests: [.init(what: "Send it", due: nil)]).facts(for: message(id: "m1"), myAddress: me),
            from: "m1"
        )
        store.clearAll()
        XCTAssertTrue(store.facts.isEmpty)
        XCTAssertFalse(store.hasExtracted("m1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUpcomingIsSoonestFirstAndWithinTheHorizon() {
        let store = FactStore(fileURL: fileURL)
        store.record(Extraction(
            requests: [.init(what: "Later", due: iso(day(10))), .init(what: "Sooner", due: iso(day(2)))],
            commitments: [.init(what: "Far off", due: iso(day(40)))],
            questions: ["Undated?"]
        ).facts(for: message(id: "m1"), myAddress: me), from: "m1")

        XCTAssertEqual(store.upcoming().map(\.text), ["Sooner", "Later"])
    }

    func testForPromptPutsDatedFirstAndCaps() {
        let store = FactStore(fileURL: fileURL)
        for index in 0..<40 {
            let due = index % 2 == 0 ? iso(day(index)) : nil
            store.record(
                Extraction(requests: [.init(what: "Task \(index)", due: due)])
                    .facts(for: message(id: "m\(index)", thread: "t\(index)"), myAddress: me),
                from: "m\(index)"
            )
        }

        let prompt = store.forPrompt()
        XCTAssertEqual(prompt.count, FactStore.promptLimit)
        XCTAssertEqual(prompt[0].text, "Task 0")
        XCTAssertTrue(prompt.prefix(20).allSatisfy { $0.due != nil })
    }

    // MARK: - Reconciling

    private func onMe(_ store: FactStore, id: String = "m1", daysAgo: Int = 3) {
        store.record(
            Extraction(requests: [.init(what: "Send the quote", due: nil)])
                .facts(for: message(id: id, daysAgo: daysAgo), myAddress: me),
            from: id
        )
    }

    func testMyLaterReplyInTheThreadCrossesOffWhatWasOnMe() {
        let store = FactStore(fileURL: fileURL)
        onMe(store)
        let thread = [
            message(id: "m1", daysAgo: 3),
            message(id: "m2", from: me, to: ["sara@x.com"], daysAgo: 1, mailbox: .sent),
        ]

        store.reconcile(with: thread, myAddress: me)

        XCTAssertTrue(store.facts[0].isDone)
        XCTAssertTrue(store.onMe.isEmpty)
    }

    func testTheirLaterMessageDoesNotCrossOffWhatIsOnMe() {
        let store = FactStore(fileURL: fileURL)
        onMe(store)
        let thread = [message(id: "m1", daysAgo: 3), message(id: "m2", daysAgo: 1)]

        store.reconcile(with: thread, myAddress: me)

        XCTAssertFalse(store.facts[0].isDone)
    }

    func testAReplyBeforeTheAskDoesNotCount() {
        let store = FactStore(fileURL: fileURL)
        onMe(store, daysAgo: 1)
        let thread = [
            message(id: "m0", from: me, to: ["sara@x.com"], daysAgo: 4, mailbox: .sent),
            message(id: "m1", daysAgo: 1),
        ]

        store.reconcile(with: thread, myAddress: me)

        XCTAssertFalse(store.facts[0].isDone)
    }

    func testAReplySentFromInsideTheAppCountsBeforeGmailReturnsIt() {
        let store = FactStore(fileURL: fileURL)
        onMe(store)

        store.reconcile(with: [message(id: "m1", daysAgo: 3)], myAddress: me, replied: ["m1"])

        XCTAssertTrue(store.facts[0].isDone)
    }

    func testTheirReplyCrossesOffWhatWasOnThem() {
        let store = FactStore(fileURL: fileURL)
        store.record(
            Extraction(commitments: [.init(what: "Share the deck", due: nil)])
                .facts(for: message(id: "m1", daysAgo: 3), myAddress: me),
            from: "m1"
        )
        let thread = [message(id: "m1", daysAgo: 3), message(id: "m2", daysAgo: 1)]

        store.reconcile(with: thread, myAddress: me)

        XCTAssertTrue(store.facts[0].isDone)
    }

    func testADateIsDoneTheDayAfter() {
        let store = FactStore(fileURL: fileURL)
        store.record(Extraction(dates: [
            .init(what: "Yesterday's meeting", due: nil, on: iso(day(-1))),
            .init(what: "Today's meeting", due: nil, on: iso(day(0))),
        ]).facts(for: message(id: "m1", daysAgo: 3), myAddress: me), from: "m1")

        store.reconcile(with: [], myAddress: me)

        XCTAssertEqual(store.open.map(\.text), ["Today's meeting"])
    }

    func testLongOverdueAndLongUndatedFactsArePruned() {
        let store = FactStore(fileURL: fileURL)
        store.record(Extraction(requests: [
            .init(what: "Very late", due: iso(day(-31))),
            .init(what: "A bit late", due: iso(day(-5))),
        ]).facts(for: message(id: "m1", daysAgo: 40), myAddress: me), from: "m1")
        store.record(Extraction(requests: [.init(what: "Old and undated", due: nil)])
            .facts(for: message(id: "m2", thread: "t2", daysAgo: 46), myAddress: me), from: "m2")
        store.record(Extraction(requests: [.init(what: "Recent and undated", due: nil)])
            .facts(for: message(id: "m3", thread: "t3", daysAgo: 10), myAddress: me), from: "m3")

        store.reconcile(with: [], myAddress: me)

        XCTAssertEqual(Set(store.facts.map(\.text)), ["A bit late", "Recent and undated"])
        // Pruned facts stay marked as read, so the message is not paid for again.
        XCTAssertTrue(store.hasExtracted("m2"))
    }

    func testNothingIsKeptPastNinetyDays() {
        let store = FactStore(fileURL: fileURL)
        store.record(Extraction(dates: [.init(what: "Ancient", due: nil, on: iso(day(200)))])
            .facts(for: message(id: "m1", daysAgo: 91), myAddress: me), from: "m1")

        store.reconcile(with: [], myAddress: me)

        XCTAssertTrue(store.facts.isEmpty)
    }

    func testFactsInAThreadShowOnItsRow() {
        let store = FactStore(fileURL: fileURL)
        store.record(Extraction(
            requests: [.init(what: "Send the quote", due: nil)],
            dates: [.init(what: "Board meeting", due: nil, on: iso(day(3)))]
        ).facts(for: message(id: "m1", thread: "t9"), myAddress: me), from: "m1")

        // The date is for Coming up, not the follow-up row.
        XCTAssertEqual(store.facts(inThread: "t9").map(\.text), ["Send the quote"])
        XCTAssertTrue(store.facts(inThread: nil).isEmpty)
    }
}
