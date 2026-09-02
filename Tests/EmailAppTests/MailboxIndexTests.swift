import XCTest
@testable import EmailApp

/// The derived numbers every screen reads, and the one thing that can go
/// wrong with caching them: showing yesterday's answer.
@MainActor
final class MailboxIndexTests: XCTestCase {

    private let me = "abel@example.com"

    private func message(
        _ subject: String,
        thread: String? = nil,
        from: String = "sara@x.com",
        daysAgo: Int = 1,
        mailbox: Mailbox = .inbox,
        isRead: Bool = false,
        tags: Set<AITag> = []
    ) -> Message {
        var message = Message(
            sender: Contact(name: from, address: from),
            recipients: [Contact(name: "Abel", address: "abel@example.com")],
            subject: subject,
            body: "Body",
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            isRead: isRead,
            mailbox: mailbox,
            tags: tags
        )
        message.remoteID = subject
        message.threadID = thread
        return message
    }

    private func store(_ messages: [Message]) -> MailStore {
        MailStore(
            account: GmailAccount(email: me, displayName: "Abel", connectedAt: .now),
            messages: messages,
            facts: FactStore(fileURL: FileManager.default.temporaryDirectory
                .appending(path: "index-\(UUID().uuidString).json"))
        )
    }

    // MARK: - The numbers

    func testUnreadCountsConversationsNotMessages() {
        let mail = store([
            message("a", thread: "t1", daysAgo: 3),
            message("b", thread: "t1", daysAgo: 1),
            message("c", thread: "t2"),
            message("d", isRead: true),
        ])

        // Two unread conversations: the t1 thread collapses to one row.
        XCTAssertEqual(mail.unreadCount(in: .inbox), 2)
    }

    func testTagCountsMatchWhatTheListShows() {
        let mail = store([
            message("a", tags: [.urgent]),
            message("b", tags: [.urgent], isRead: true),
            message("c", tags: [.needsReply]),
        ])

        XCTAssertEqual(mail.count(of: .urgent, in: .inbox), 2)
        XCTAssertEqual(mail.unreadCount(of: .urgent, in: .inbox), 1)
        XCTAssertEqual(mail.messages(in: .inbox, tag: .urgent).count, 2)
        XCTAssertEqual(Set(mail.availableTags(in: .inbox)), [.urgent, .needsReply])
    }

    func testThreadCountIsTheWholeThread() {
        let mail = store([
            message("a", thread: "t1", daysAgo: 3),
            message("b", thread: "t1", daysAgo: 2),
            message("c", thread: "t1", daysAgo: 1),
            message("d", thread: "t2"),
            message("e"),
        ])

        let top = mail.messages(in: .inbox)
        XCTAssertEqual(mail.threadCount(for: top.first { $0.threadID == "t1" }!), 3)
        XCTAssertEqual(mail.threadCount(for: top.first { $0.threadID == "t2" }!), 1)
        // No thread at all is a conversation of one, not of zero.
        XCTAssertEqual(mail.threadCount(for: top.first { $0.threadID == nil }!), 1)
    }

    func testTheListIsNewestFirstAndCollapsed() {
        let mail = store([
            message("old", daysAgo: 9),
            message("a", thread: "t1", daysAgo: 5),
            message("newest", thread: "t1", daysAgo: 1),
        ])

        XCTAssertEqual(mail.messages(in: .inbox).map(\.subject), ["newest", "old"])
    }

    func testSentAndInboxAreSeparate() {
        let mail = store([
            message("in"),
            message("out", from: me, mailbox: .sent),
        ])

        XCTAssertEqual(mail.messages(in: .inbox).map(\.subject), ["in"])
        XCTAssertEqual(mail.messages(in: .sent).map(\.subject), ["out"])
        XCTAssertEqual(mail.unreadCount(in: .sent), 1)
    }

    // MARK: - Staying honest

    func testMarkingReadMovesEveryNumberThatDependsOnIt() {
        let mail = store([
            message("a", tags: [.urgent]),
            message("b", tags: [.urgent]),
        ])
        XCTAssertEqual(mail.unreadCount(in: .inbox), 2)
        XCTAssertEqual(mail.unreadCount(of: .urgent, in: .inbox), 2)

        let first = mail.messages(in: .inbox)[0]
        mail.markRead(first.id, true)

        XCTAssertEqual(mail.unreadCount(in: .inbox), 1)
        XCTAssertEqual(mail.unreadCount(of: .urgent, in: .inbox), 1)
        // Still two of them, only one unread.
        XCTAssertEqual(mail.count(of: .urgent, in: .inbox), 2)
    }

    func testDeletingMovesTheCountsAndTheThreadSize() {
        let mail = store([
            message("a", thread: "t1", daysAgo: 2),
            message("b", thread: "t1", daysAgo: 1),
        ])
        let newest = mail.messages(in: .inbox)[0]
        XCTAssertEqual(mail.threadCount(for: newest), 2)

        mail.delete(newest.id)

        // Trashed, not gone: out of the inbox, into the trash.
        XCTAssertEqual(mail.messages(in: .inbox).count, 1)
        XCTAssertEqual(mail.messages(in: .trash).count, 1)
        XCTAssertEqual(mail.unreadCount(in: .inbox), 1)
    }

    func testForgettingDropsItFromEveryList() {
        let mail = store([message("a"), message("b")])
        mail.forget(remoteIDs: ["a"])

        XCTAssertEqual(mail.messages(in: .inbox).map(\.subject), ["b"])
        XCTAssertEqual(mail.unreadCount(in: .inbox), 1)
        XCTAssertNil(mail.messages.first { $0.remoteID == "a" })
    }

    func testAbsorbingSearchResultsShowsUpInTheCounts() {
        let mail = store([message("a")])
        mail.absorb([message("b", daysAgo: 40), message("a")])

        // The duplicate is refused; the new one lands.
        XCTAssertEqual(mail.messages.count, 2)
        XCTAssertEqual(mail.unreadCount(in: .inbox), 2)
    }

    func testDisconnectingEmptiesEverything() {
        let mail = store([message("a", tags: [.urgent])])
        mail.disconnect()

        XCTAssertEqual(mail.unreadCount(in: .inbox), 0)
        XCTAssertEqual(mail.count(of: .urgent, in: .inbox), 0)
        XCTAssertTrue(mail.messages(in: .inbox).isEmpty)
        XCTAssertTrue(mail.followUps.isEmpty)
    }

    func testLookupByIDSurvivesTheListChangingUnderIt() {
        let mail = store([message("a"), message("b"), message("c")])
        let wanted = mail.messages(in: .inbox).first { $0.subject == "c" }!

        // Removing something ahead of it shifts every position after it.
        mail.forget(remoteIDs: ["a"])

        XCTAssertEqual(mail.message(wanted.id)?.subject, "c")
        mail.markRead(wanted.id, true)
        XCTAssertEqual(mail.message(wanted.id)?.isRead, true)
    }

    // MARK: - Follow-ups

    func testFollowUpsComeOffTheIndexAndMoveWithTheMail() {
        let mail = store([
            message("sent", thread: "t1", from: me, daysAgo: 10, mailbox: .sent),
        ])
        XCTAssertEqual(mail.followUps.map(\.direction), [.waitingOnThem])

        // They answered. The ball is no longer with them.
        mail.absorb([message("reply", thread: "t1", daysAgo: 1)])
        XCTAssertTrue(mail.followUps.filter { $0.direction == .waitingOnThem }.isEmpty)
    }

    func testDismissingAFollowUpTakesItOutWithoutTheMailChanging() {
        FollowUpPreferences.clearAll()
        defer { FollowUpPreferences.clearAll() }

        let mail = store([
            message("sent", thread: "t1", from: me, daysAgo: 10, mailbox: .sent),
        ])
        XCTAssertEqual(mail.followUps.count, 1)

        mail.dismissFollowUp("t1")

        XCTAssertTrue(mail.followUps.isEmpty)
    }
}
