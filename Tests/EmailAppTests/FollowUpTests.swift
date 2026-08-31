import XCTest
@testable import EmailApp

final class FollowUpTests: XCTestCase {

    private let me = "abel@example.com"

    private func message(
        thread: String,
        from: String,
        daysAgo: Int,
        mailbox: Mailbox = .inbox,
        tags: Set<AITag> = []
    ) -> Message {
        var message = Message(
            sender: Contact(name: from, address: from),
            recipients: [],
            subject: "Subject",
            body: "Body",
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            mailbox: mailbox,
            tags: tags
        )
        message.threadID = thread
        return message
    }

    // MARK: - Waiting on them

    func testAMessageISentAndNobodyAnsweredIsWaitingOnThem() {
        let followUps = [
            message(thread: "t1", from: me, daysAgo: 10, mailbox: .sent)
        ].followUps(myAddress: me)

        XCTAssertEqual(followUps.count, 1)
        XCTAssertEqual(followUps[0].direction, .waitingOnThem)
        XCTAssertTrue(followUps[0].isOverdue)
    }

    func testSomethingSentTodayIsNotAFollowUpYet() {
        // Everything in Sent would otherwise show up as needing a chase.
        let followUps = [
            message(thread: "t1", from: me, daysAgo: 0, mailbox: .sent)
        ].followUps(myAddress: me)
        XCTAssertTrue(followUps.isEmpty)
    }

    func testTheirReplyClearsTheFollowUp() {
        // My message, then theirs on top. The ball is no longer with them, and
        // it should drop out without anything having to clear it explicitly.
        let followUps = [
            message(thread: "t1", from: me, daysAgo: 10, mailbox: .sent),
            message(thread: "t1", from: "sara@x.com", daysAgo: 2),
        ].followUps(myAddress: me)

        XCTAssertTrue(followUps.filter { $0.direction == .waitingOnThem }.isEmpty)
    }

    // MARK: - Waiting on you

    func testAnIncomingMessageNeedingAReplyIsWaitingOnYou() {
        let followUps = [
            message(thread: "t1", from: "sara@x.com", daysAgo: 2, tags: [.needsReply])
        ].followUps(myAddress: me)

        XCTAssertEqual(followUps.count, 1)
        XCTAssertEqual(followUps[0].direction, .waitingOnYou)
    }

    func testAnIncomingMessageThatNeedsNoReplyIsNotAFollowUp() {
        let followUps = [
            message(thread: "t1", from: "news@x.com", daysAgo: 2, tags: [.noReplyNeeded])
        ].followUps(myAddress: me)
        XCTAssertTrue(followUps.isEmpty)
    }

    func testMyReplyClearsWhatWasWaitingOnMe() {
        let followUps = [
            message(thread: "t1", from: "sara@x.com", daysAgo: 5, tags: [.needsReply]),
            message(thread: "t1", from: me, daysAgo: 4, mailbox: .sent),
        ].followUps(myAddress: me)

        XCTAssertTrue(followUps.filter { $0.direction == .waitingOnYou }.isEmpty)
    }

    // MARK: - Overdue and ordering

    func testWaitingOnThemIsNotOverdueBeforeAWeek() {
        let followUps = [
            message(thread: "t1", from: me, daysAgo: 5, mailbox: .sent)
        ].followUps(myAddress: me)
        XCTAssertFalse(followUps[0].isOverdue)
    }

    func testOverdueSortsAboveEverythingElse() {
        let followUps = [
            message(thread: "recent", from: "a@x.com", daysAgo: 1, tags: [.needsReply]),
            message(thread: "old", from: me, daysAgo: 20, mailbox: .sent),
        ].followUps(myAddress: me)

        XCTAssertEqual(followUps.first?.id, "old")
        XCTAssertTrue(followUps[0].isOverdue)
    }

    func testOlderSortsFirstWithinTheSameUrgency() {
        let followUps = [
            message(thread: "newer", from: "a@x.com", daysAgo: 1, tags: [.needsReply]),
            message(thread: "older", from: "b@x.com", daysAgo: 4, tags: [.needsReply]),
        ].followUps(myAddress: me)

        XCTAssertEqual(followUps.first?.id, "older")
    }

    // MARK: - Wording

    func testAgeReadsLikeAPersonWouldSayIt() {
        let followUps = [
            message(thread: "t1", from: me, daysAgo: 4, mailbox: .sent)
        ].followUps(myAddress: me)
        XCTAssertEqual(followUps[0].ageDescription, "4 days ago")
    }

    func testWeeksAreRoundedNotSpelledOutInDays() {
        let followUps = [
            message(thread: "t1", from: me, daysAgo: 21, mailbox: .sent)
        ].followUps(myAddress: me)
        XCTAssertEqual(followUps[0].ageDescription, "3 weeks ago")
    }
}
