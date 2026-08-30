import XCTest
@testable import EmailApp

@MainActor
final class InsightsTests: XCTestCase {

    private let alice = Contact(name: "Alice Adams", address: "alice@example.com")
    private let bob = Contact(name: "Bob Brown", address: "bob@example.com")

    /// Mail always arrives with a connected account -- `connect()` sets both
    /// together -- so fixtures must too, or `inboxStatus` correctly reports
    /// that there is no inbox.
    private func connected(_ messages: [Message]) -> MailStore {
        MailStore(
            account: GmailAccount(email: "abel@example.com", displayName: "Abel Amare", connectedAt: .now),
            messages: messages
        )
    }

    private func makeStore() -> MailStore {
        connected([
            Message(sender: alice, recipients: [], subject: "Wire approval",
                    body: "needs sign-off", date: .now, isRead: false, mailbox: .inbox,
                    tags: [.urgent, .needsReply]),
            Message(sender: alice, recipients: [], subject: "Follow up",
                    body: "checking in", date: .now.addingTimeInterval(-3600),
                    isRead: true, mailbox: .inbox, tags: [.needsReply]),
            Message(sender: bob, recipients: [], subject: "Design review",
                    body: "thursday works", date: .now.addingTimeInterval(-7200),
                    isRead: false, mailbox: .inbox, tags: [.veryImportant, .needsReply]),
            Message(sender: bob, recipients: [], subject: "Newsletter",
                    body: "weekly digest", date: .now.addingTimeInterval(-10800),
                    isRead: true, mailbox: .inbox, tags: [.noReplyNeeded]),
            Message(sender: bob, recipients: [], subject: "Receipt",
                    body: "your order", date: .now.addingTimeInterval(-14400),
                    isRead: true, mailbox: .inbox, tags: [.noReplyNeeded]),
            Message(sender: alice, recipients: [], subject: "Trashed",
                    body: "gone", date: .now, isRead: false, mailbox: .trash,
                    tags: [.urgent]),
        ])
    }

    // MARK: - Counts

    func testCountsIgnoreOtherMailboxes() {
        let counts = makeStore().counts
        XCTAssertEqual(counts.new, 2, "only unread inbox mail counts, not the trashed one")
        XCTAssertEqual(counts.urgent, 1)
        XCTAssertEqual(counts.needsReply, 3)
        XCTAssertEqual(counts.important, 1, "veryImportant counts toward important")
    }

    func testCalmInboxHasNoUrgentOrReplies() {
        let calm = connected([
            Message(sender: alice, recipients: [], subject: "FYI", body: "-",
                    date: .now, isRead: true, mailbox: .inbox, tags: [.noReplyNeeded]),
        ])
        XCTAssertTrue(calm.counts.isCalm)
        XCTAssertEqual(calm.inboxStatus, "Your inbox is under control.")
    }

    func testStatusLeadsWithUrgent() {
        XCTAssertEqual(makeStore().inboxStatus, "One email needs you right away.")
    }

    func testStatusFallsBackToRepliesWhenNothingIsUrgent() {
        let store = connected([
            Message(sender: alice, recipients: [], subject: "A", body: "-",
                    date: .now, mailbox: .inbox, tags: [.needsReply]),
            Message(sender: bob, recipients: [], subject: "B", body: "-",
                    date: .now, mailbox: .inbox, tags: [.needsReply]),
        ])
        XCTAssertEqual(store.inboxStatus, "2 replies are waiting on you.")
    }

    func testDisconnectedStoreAsksForAnInbox() {
        XCTAssertEqual(MailStore().inboxStatus, "Connect an inbox to get started.")
    }

    // MARK: - Needs attention

    func testNeedsAttentionPutsUrgentFirst() {
        let subjects = makeStore().needsAttention().map(\.subject)
        XCTAssertEqual(subjects.first, "Wire approval")
    }

    func testNeedsAttentionExcludesTrash() {
        XCTAssertFalse(makeStore().needsAttention(limit: 10).contains { $0.subject == "Trashed" })
    }

    func testNeedsAttentionRespectsTheLimit() {
        XCTAssertEqual(makeStore().needsAttention(limit: 2).count, 2)
    }

    // MARK: - Recommendations

    func testRecommendationsSurfaceClutter() {
        let ids = makeStore().recommendations.map(\.id)
        XCTAssertTrue(ids.contains("clutter"), "two noReplyNeeded messages should suggest filing")
    }

    func testRecommendationsAreEmptyForACleanInbox() {
        let clean = connected([
            Message(sender: alice, recipients: [], subject: "A", body: "-",
                    date: .now, isRead: true, mailbox: .inbox, tags: [.noReplyNeeded]),
        ])
        XCTAssertTrue(clean.recommendations.isEmpty, "a single message should not trigger advice")
    }

    // MARK: - People

    func testPeopleAreGroupedBySender() {
        let people = makeStore().people
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(Set(people.map(\.contact.address)), [alice.address, bob.address])
    }

    func testPeopleCountConversations() {
        let people = makeStore().people
        // Alice: 2 inbox + 1 trashed = 3 total; People spans the whole mailbox.
        XCTAssertEqual(people.first { $0.contact.address == alice.address }?.conversationCount, 3)
    }

    func testPeopleAwaitingReplySortFirst() {
        let store = connected([
            Message(sender: bob, recipients: [], subject: "Quiet", body: "-",
                    date: .now, isRead: true, mailbox: .inbox, tags: [.noReplyNeeded]),
            Message(sender: alice, recipients: [], subject: "Waiting", body: "-",
                    date: .now.addingTimeInterval(-9999), mailbox: .inbox, tags: [.needsReply]),
        ])
        XCTAssertEqual(store.people.first?.contact.address, alice.address,
                       "someone awaiting a reply outranks a more recent quiet contact")
    }

    func testPeopleNeverIncludeTheUser() {
        let store = connected([
            Message(sender: .me, recipients: [alice], subject: "Sent", body: "-",
                    date: .now, isRead: true, mailbox: .sent),
        ])
        XCTAssertTrue(store.people.isEmpty)
    }

    func testPriorityContactIsFlagged() {
        let people = makeStore().people
        XCTAssertEqual(people.first { $0.contact.address == bob.address }?.isPriority, true)
    }

    // MARK: - AI questions

    func testEveryAIQuestionResolvesAgainstTheStore() {
        let store = makeStore()
        for question in AIQuestion.all {
            // Must not trap, and a tagged question must only return that tag.
            let results = store.messages(in: .inbox, tag: question.tag)
            if let tag = question.tag {
                XCTAssertTrue(results.allSatisfy { $0.tags.contains(tag) }, "\(question.id) leaked untagged mail")
            }
        }
    }

    func testAIQuestionIdsAreUnique() {
        let ids = AIQuestion.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
