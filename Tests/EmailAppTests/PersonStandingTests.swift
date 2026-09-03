import XCTest
@testable import EmailApp

/// Where things stand with one person, assembled from three places the app
/// already keeps: who they are, what the mail committed either side to, and
/// whose move it is.
///
/// The point is that "what's happening with Sara" stops meaning "here are a
/// dozen of Sara's emails, work it out".
@MainActor
final class PersonStandingTests: XCTestCase {

    private let me = "abel@example.com"
    private var factsURL: URL!

    override func setUp() {
        super.setUp()
        factsURL = FileManager.default.temporaryDirectory
            .appending(path: "f-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: factsURL)
        super.tearDown()
    }

    private func message(
        _ id: String,
        from: String = "sara@x.com",
        name: String = "Sara Chen",
        thread: String = "t1",
        daysAgo: Int = 2,
        mailbox: Mailbox = .inbox,
        tags: Set<AITag> = []
    ) -> Message {
        var message = Message(
            sender: Contact(name: from == me ? "Abel" : name, address: from),
            recipients: [Contact(name: from == me ? name : "Abel", address: from == me ? "sara@x.com" : me)],
            subject: "Q3 pricing",
            body: "Body",
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            mailbox: mailbox,
            tags: tags
        )
        message.remoteID = id
        message.threadID = thread
        return message
    }

    private func store(_ messages: [Message]) -> MailStore {
        MailStore(
            account: MailAccount(provider: .gmail, address: me, displayName: "Abel"), registry: .throwaway(),
            messages: messages,
            facts: FactStore(fileURL: factsURL)
        )
    }

    // MARK: - The join

    func testStandingPullsTogetherWhoTheyAreAndWhatIsOutstanding() {
        let mail = store([message("m1", tags: [.needsReply])])
        mail.facts.record(
            Extraction(
                requests: [.init(what: "Send the revised quote", due: nil)],
                commitments: [.init(what: "Share the deck", due: nil)]
            ).facts(for: message("m1"), myAddress: me),
            from: "m1"
        )

        let standing = mail.standing(for: "sara@x.com")
        XCTAssertNotNil(standing)
        XCTAssertEqual(standing?.name, "Sara Chen")
        // Their ask lands on me; their promise stays with them.
        XCTAssertEqual(standing?.onMe.map(\.text), ["Send the revised quote"])
        XCTAssertEqual(standing?.onThem.map(\.text), ["Share the deck"])
        XCTAssertTrue(standing?.hasOutstanding == true)
    }

    func testDatesAreSeparatedFromWhoOwesWhat() {
        let mail = store([message("m1")])
        mail.facts.record(
            Extraction(dates: [.init(what: "Board meeting", due: nil, on: iso(3))])
                .facts(for: message("m1"), myAddress: me),
            from: "m1"
        )

        let standing = mail.standing(for: "sara@x.com")
        XCTAssertEqual(standing?.coming.map(\.text), ["Board meeting"])
        XCTAssertTrue(standing?.onMe.isEmpty == true)
        XCTAssertTrue(standing?.onThem.isEmpty == true)
    }

    func testSomebodyWithNothingOutstandingIsStillAPerson() {
        let mail = store([message("m1")])
        let standing = mail.standing(for: "sara@x.com")
        XCTAssertNotNil(standing)
        XCTAssertFalse(standing?.hasOutstanding == true)
    }

    func testAStrangerHasNoStanding() {
        let mail = store([message("m1")])
        XCTAssertNil(mail.standing(for: "nobody@nowhere.com"))
    }

    // MARK: - What the model reads

    func testTheDescriptionNamesWhoOwesWhat() {
        let mail = store([message("m1", tags: [.needsReply])])
        mail.facts.record(
            Extraction(requests: [.init(what: "Send the revised quote", due: nil)])
                .facts(for: message("m1"), myAddress: me),
            from: "m1"
        )

        let text = mail.standing(for: "sara@x.com")!.described()
        XCTAssertTrue(text.contains("Sara Chen"))
        XCTAssertTrue(text.contains("- On you:"))
        XCTAssertTrue(text.contains("Send the revised quote"))
        XCTAssertTrue(text.contains("messages across"), "history is part of who somebody is")
    }

    func testTheDescriptionLeavesOutWhatIsNotThere() {
        let mail = store([message("m1")])
        let text = mail.standing(for: "sara@x.com")!.described()
        XCTAssertFalse(text.contains("- On you:"))
        XCTAssertFalse(text.contains("- Coming up:"))
    }

    // MARK: - Who a question is about

    func testAQuestionNamingSomebodyBringsTheirStanding() {
        let mail = store([message("m1")])
        XCTAssertEqual(
            mail.peopleMentioned(in: "what's happening with Sara?").map(\.name),
            ["Sara Chen"]
        )
        XCTAssertEqual(
            mail.peopleMentioned(in: "anything from sara@x.com").map(\.name),
            ["Sara Chen"]
        )
    }

    func testAQuestionAboutNobodyBringsNobody() {
        let mail = store([message("m1")])
        XCTAssertTrue(mail.peopleMentioned(in: "what needs a reply today?").isEmpty)
    }

    func testANameInsideAnotherWordIsNotAMatch() {
        // "Sam" must not match "same", which is the failure that would put a
        // stranger's history in front of the model on every other question.
        var sam = message("m1", from: "sam@x.com", name: "Sam Rivera")
        sam.threadID = "t2"
        let mail = store([sam])
        XCTAssertTrue(mail.peopleMentioned(in: "is that the same invoice?").isEmpty)
        XCTAssertEqual(mail.peopleMentioned(in: "what did Sam want?").count, 1)
    }

    func testShortNamesAreNotMatchedAtAll() {
        // Two letters is a word more often than a name.
        let jo = message("m1", from: "jo@x.com", name: "Jo")
        let mail = store([jo])
        XCTAssertTrue(mail.peopleMentioned(in: "what is my job situation").isEmpty)
    }

    func testSomebodyWithSomethingOutstandingComesFirst() {
        let sara = message("m1", from: "sara@x.com", name: "Sara Chen", thread: "t1")
        var tom = message("m2", from: "tom@y.com", name: "Tom Ellis", thread: "t2")
        tom.remoteID = "m2"
        let mail = store([sara, tom])
        mail.facts.record(
            Extraction(requests: [.init(what: "Send the quote", due: nil)])
                .facts(for: tom, myAddress: me),
            from: "m2"
        )

        let named = mail.peopleMentioned(in: "where are we with Sara and Tom?")
        XCTAssertEqual(named.first?.name, "Tom Ellis", "the one you owe something comes first")
        XCTAssertEqual(named.count, 2)
    }

    func testOnlyTwoPeopleAtATime() {
        let mail = store([
            message("m1", from: "sara@x.com", name: "Sara Chen", thread: "t1"),
            message("m2", from: "tom@y.com", name: "Tom Ellis", thread: "t2"),
            message("m3", from: "nina@z.com", name: "Nina Patel", thread: "t3"),
        ])
        XCTAssertEqual(mail.peopleMentioned(in: "Sara, Tom and Nina").count, 2)
    }

    // MARK: - The thread a reply belongs to

    func testAThreadSummaryIsTheLastFewMessagesOldestFirst() {
        let mail = store([
            message("m1", daysAgo: 5),
            message("m2", from: me, daysAgo: 3, mailbox: .sent),
            message("m3", daysAgo: 1),
        ])
        let summary = mail.threadSummary(for: mail.messages.first { $0.remoteID == "m3" }!)

        XCTAssertTrue(summary.contains("Sara Chen wrote on"))
        XCTAssertTrue(summary.contains("Abel wrote on"))
        // The message being replied to is not in its own context.
        XCTAssertEqual(summary.components(separatedBy: "wrote on").count - 1, 2)
    }

    func testAMessageWithNoThreadHasNoSummary() {
        var loose = message("m1")
        loose.threadID = nil
        let mail = store([loose])
        XCTAssertEqual(mail.threadSummary(for: loose), "")
    }

    private func iso(_ daysFromNow: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: .now)!
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
