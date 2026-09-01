import XCTest
@testable import EmailApp

@MainActor
final class MailStoreTests: XCTestCase {

    private func makeStore() -> MailStore {
        MailStore(messages: [
            Message(sender: .me, recipients: [], subject: "One",
                    body: "hello world", date: .now, isRead: false, mailbox: .inbox,
                    tags: [.urgent, .needsReply]),
            Message(sender: .me, recipients: [], subject: "Two",
                    body: "goodbye", date: .now.addingTimeInterval(-60),
                    isRead: true, isFlagged: true, mailbox: .inbox,
                    tags: [.noReplyNeeded]),
            Message(sender: .me, recipients: [], subject: "Three",
                    body: "already gone", date: .now, isRead: false, mailbox: .trash,
                    tags: [.urgent]),
        ])
    }

    // MARK: - Mailboxes

    func testUnreadCountIgnoresOtherMailboxes() {
        XCTAssertEqual(makeStore().unreadCount(in: .inbox), 1)
    }

    func testMessagesAreSortedNewestFirst() {
        XCTAssertEqual(makeStore().messages(in: .inbox).map(\.subject), ["One", "Two"])
    }

    func testSearchMatchesBodyAndSubject() {
        let store = makeStore()
        XCTAssertEqual(store.messages(in: .inbox, matching: "goodbye").map(\.subject), ["Two"])
        XCTAssertEqual(store.messages(in: .inbox, matching: "one").map(\.subject), ["One"])
        XCTAssertTrue(store.messages(in: .inbox, matching: "nothing").isEmpty)
    }

    func testFlaggedIsASmartMailboxAcrossFolders() {
        XCTAssertEqual(makeStore().messages(in: .flagged).map(\.subject), ["Two"])
    }

    func testDeleteMovesToTrashThenRemoves() {
        let store = makeStore()
        let id = store.messages(in: .inbox)[0].id

        store.delete(id)
        XCTAssertEqual(store.message(id)?.mailbox, .trash)

        store.delete(id)
        XCTAssertNil(store.message(id))
    }

    // MARK: - AI tags

    func testFilteringByTag() {
        let store = makeStore()
        XCTAssertEqual(store.messages(in: .inbox, tag: .urgent).map(\.subject), ["One"])
        XCTAssertEqual(store.messages(in: .inbox, tag: .noReplyNeeded).map(\.subject), ["Two"])
        XCTAssertTrue(store.messages(in: .inbox, tag: .important).isEmpty)
    }

    func testTagCountIsScopedToTheMailbox() {
        // Two messages are tagged .urgent, but one of them is in the trash.
        XCTAssertEqual(makeStore().count(of: .urgent, in: .inbox), 1)
        XCTAssertEqual(makeStore().count(of: .urgent, in: .trash), 1)
    }

    func testAvailableTagsOmitsEmptyOnes() {
        // A chip that would empty the list should never be offered.
        XCTAssertEqual(makeStore().availableTags(in: .inbox), [.urgent, .needsReply, .noReplyNeeded])
    }

    func testAvailableTagsAreInDeclarationOrder() {
        let tags = makeStore().availableTags(in: .inbox)
        XCTAssertEqual(tags, AITag.allCases.filter(tags.contains))
    }

    func testTagAndSearchCombine() {
        let store = makeStore()
        XCTAssertEqual(store.messages(in: .inbox, tag: .urgent, matching: "hello").count, 1)
        XCTAssertEqual(store.messages(in: .inbox, tag: .urgent, matching: "goodbye").count, 0)
    }

    func testTopPriorityPicksTheLoudestTag() {
        let message = Message(sender: .me, recipients: [], subject: "", body: "",
                              date: .now, tags: [.important, .urgent, .needsReply])
        XCTAssertEqual(message.topPriority, .urgent)
    }

    func testTopPriorityIsNilWithoutAPriorityTag() {
        let message = Message(sender: .me, recipients: [], subject: "", body: "",
                              date: .now, tags: [.needsReply, .noReplyNeeded])
        XCTAssertNil(message.topPriority)
    }

    // MARK: - Connection

    func testStartsDisconnectedAndEmpty() {
        let store = MailStore()
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(store.messages.isEmpty)
    }

    /// `connect()` now performs a real Google consent flow, which cannot run
    /// in a unit test -- with no signed-in user and no view controller to
    /// present from, it blocks forever rather than failing. So these cover the
    /// connected/disconnected state machine directly instead.
    func testAStoreWithAnAccountIsConnected() {
        let store = MailStore.connected()
        XCTAssertTrue(store.isConnected)
        XCTAssertFalse(store.messages.isEmpty)
        XCTAssertFalse(store.availableTags(in: .inbox).isEmpty)
    }

    func testDisconnectClearsEverything() {
        let store = MailStore.connected()
        XCTAssertTrue(store.isConnected)

        store.disconnect()

        XCTAssertFalse(store.isConnected)
        XCTAssertNil(store.account)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.connectionError)
    }

    func testRefreshDoesNothingWhenNoMailboxIsConnected() async {
        // Guarded by `isConnected`, so it returns immediately and never
        // reaches the network.
        let store = MailStore()
        await store.refresh()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(store.messages.isEmpty)
    }

    // MARK: - Compose

    // Sending used to append a message to the local Sent folder and make no
    // network call at all -- the mail never left the device. It now goes
    // through Gmail, so the old "it appears in Sent" tests were asserting the
    // bug. What is left to check without a network is that it refuses, loudly,
    // rather than pretending to succeed.

    func testSendWithoutAnAccountThrows() async {
        let store = makeStore()
        XCTAssertFalse(store.isConnected)

        do {
            try await store.send(subject: "Hi", to: "a@b.com", body: "there")
            XCTFail("Sending with no connected account should throw")
        } catch {
            XCTAssertTrue(error is MailStore.SendError)
        }
    }

    func testSendFailureLeavesNothingInSent() async {
        // The local copy is only recorded once Gmail has accepted the message.
        // A failed send that still filed a copy in Sent would tell the user it
        // went when it did not.
        let store = makeStore()
        try? await store.send(subject: "Hi", to: "a@b.com", body: "there")
        XCTAssertTrue(store.messages(in: .sent).isEmpty)
    }

    func testSaveDraftWithoutAnAccountThrows() async {
        let store = makeStore()
        do {
            try await store.saveDraft(subject: "Hi", to: "a@b.com", body: "there")
            XCTFail("Saving a draft with no connected account should throw")
        } catch {
            XCTAssertTrue(error is MailStore.SendError)
        }
    }

    // MARK: - Chip counts

    func testChipCountOnlyCountsUnread() {
        // The pill number is a to-do count: reading the message clears it.
        let store = makeStore()
        XCTAssertEqual(store.unreadCount(of: .urgent, in: .inbox), 1)

        store.markRead(store.messages(in: .inbox)[0].id)
        XCTAssertEqual(store.unreadCount(of: .urgent, in: .inbox), 0)
    }

    // MARK: - Answering stops the nagging

    func testReplyingClearsTheNeedsReplyTag() {
        let store = makeStore()
        let id = store.messages(in: .inbox)[0].id
        XCTAssertTrue(store.message(id)?.tags.contains(.needsReply) ?? false)

        store.markReplied(id)

        XCTAssertFalse(store.message(id)?.tags.contains(.needsReply) ?? true)
        XCTAssertTrue(store.message(id)?.isRead ?? false)
        XCTAssertTrue(store.messages(in: .inbox, tag: .needsReply).isEmpty)
    }

    func testWhatTheModelIsToldAboutReadingIsTrue() {
        // The model decides the wording now, so what matters here is that it
        // is told the truth about what has been read.
        let store = makeStore()
        XCTAssertTrue(store.tagSummary.contains("Needs Reply 1 (1 unread)"), store.tagSummary)

        store.markRead(store.messages(in: .inbox)[0].id)
        XCTAssertTrue(store.tagSummary.contains("Needs Reply 1 (0 unread)"), store.tagSummary)
    }

    func testTagSummaryNamesEveryPileWithACount() {
        let summary = makeStore().tagSummary
        XCTAssertTrue(summary.contains("Very Urgent 1"), summary)
        XCTAssertTrue(summary.contains("No Reply Needed 1"), summary)
    }

    // MARK: - What the model is sent

    func testAQuestionAboutNothingSendsNoMailAtAll() {
        // This is the token leak: a recency bonus handed over a dozen emails
        // for a question that had nothing to do with any of them.
        XCTAssertTrue(makeStore().context(for: "What can you do?").isEmpty)
        XCTAssertTrue(makeStore().context(for: "Write me a haiku about rain").isEmpty)
    }

    func testAQuestionAboutMailStillGetsMail() {
        XCTAssertFalse(makeStore().context(for: "What is urgent in my inbox?").isEmpty)
        XCTAssertFalse(makeStore().context(for: "anything about goodbye?").isEmpty)
    }

    func testAShortReplyInheritsWhatItIsReplyingTo() {
        // "Yes" on its own retrieves nothing, so the model would answer an
        // offer it had made with no mail in front of it.
        let store = makeStore()
        XCTAssertTrue(store.context(for: "yes").isEmpty)
        XCTAssertFalse(
            store.context(for: "yes", following: "One urgent email is sitting there. Want it?").isEmpty
        )
    }

    func testALongQuestionDoesNotInheritTheLastAnswer() {
        // Only short follow-ups borrow context. A real question stands alone,
        // or every answer would drag the previous one's subject along.
        XCTAssertTrue(
            makeStore()
                .context(for: "Write me a haiku about rain", following: "3 urgent emails are waiting")
                .isEmpty
        )
    }

    // MARK: - Order, and knowing when the phone does not have the answer

    func testTheNewestMessageIsAlwaysSentAndComesFirst() {
        // "What was the last email I got" is a question about order. Ranking
        // by relevance answered it with whatever was most urgent and left the
        // newest message out of the digest entirely.
        let store = MailStore(messages: [
            Message(sender: .me, recipients: [], subject: "Newest", body: "nothing special",
                    date: .now, mailbox: .inbox, tags: [.noReplyNeeded]),
            Message(sender: .me, recipients: [], subject: "Older but urgent", body: "urgent thing",
                    date: .now.addingTimeInterval(-86_400), mailbox: .inbox, tags: [.urgent, .needsReply]),
        ])

        let context = store.context(for: "what was the last email I got")
        XCTAssertEqual(context.first?.subject, "Newest", context.map(\.subject).description)
    }

    func testTheDigestIsOrderedNewestFirst() {
        let store = MailStore(messages: [
            Message(sender: .me, recipients: [], subject: "Old", body: "urgent",
                    date: .now.addingTimeInterval(-86_400), mailbox: .inbox, tags: [.urgent]),
            Message(sender: .me, recipients: [], subject: "New", body: "quiet",
                    date: .now, mailbox: .inbox, tags: [.noReplyNeeded]),
        ])

        let dates = store.context(for: "anything urgent in my inbox").map(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }

    func testAWordInABodyIsNotEvidenceTheAnswerIsHere() {
        // The bug: "find me my registration date on upwork" matched the word
        // "date" in an unrelated message, so the archive was judged to hold
        // the answer and Gmail was never asked about an email that existed.
        let store = MailStore(messages: [
            Message(sender: .me, recipients: [], subject: "Standup",
                    body: "Let us agree a date for the review.",
                    date: .now, mailbox: .inbox),
        ])

        XCTAssertFalse(store.hasStrongMatch(for: "find me my registration date on upwork"))
    }

    func testASubjectOrSenderMatchIsEvidence() {
        let store = MailStore(messages: [
            Message(sender: Contact(name: "Upwork", address: "no-reply@upwork.com"),
                    recipients: [], subject: "Welcome to Upwork", body: "hello",
                    date: .now, mailbox: .inbox),
        ])

        XCTAssertTrue(store.hasStrongMatch(for: "find me my registration date on upwork"))
    }

    func testLookingSomethingUpCountsAsAMailQuestion() {
        // None of these say "email", and all of them are about mail.
        let store = makeStore()
        for question in [
            "find me my registration date on upwork",
            "when did I sign up for that",
            "do I have a receipt for the flight",
        ] {
            XCTAssertTrue(store.looksLikeMailQuestion(question), question)
        }
    }
}
