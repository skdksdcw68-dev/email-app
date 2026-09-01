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

    // MARK: - Local answers

    func testReplyQuestionIsAnsweredLocally() {
        // Level 1 of the decision ladder: the mailbox settles this itself,
        // instantly and free, so it must never reach the model.
        let answer = makeStore().localAnswer(for: "What do I need to reply to?")
        XCTAssertNotNil(answer)
        XCTAssertFalse(answer?.text.isEmpty ?? true)
    }

    func testOpenQuestionsGoToTheModel() {
        // Anything with real nuance falls through to level 2.
        XCTAssertNil(makeStore().localAnswer(for: "Summarise the contract negotiation"))
    }

    func testAnEmptyMailboxAnswersNothingLocally() {
        XCTAssertNil(MailStore().localAnswer(for: "What do I need to reply to?"))
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

    func testReadMailIsPhrasedAsASuggestion() {
        // The whole point: an email you have already seen and chosen not to
        // answer must not be barked at you as a task.
        let store = makeStore()
        store.markRead(store.messages(in: .inbox)[0].id)

        let answer = store.localAnswer(for: "What do I need to reply to?")
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer?.text.contains("already read") ?? false, answer?.text ?? "no answer")
    }

    func testUnreadMailIsStatedPlainly() {
        let answer = makeStore().localAnswer(for: "What do I need to reply to?")
        XCTAssertTrue(answer?.text.contains("waiting on a reply") ?? false, answer?.text ?? "no answer")
    }

    // MARK: - Tag questions

    func testAskingForATagListsThatPile() {
        let answer = makeStore().localAnswer(for: "show me very urgent")
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer?.text.contains("Very Urgent") ?? false, answer?.text ?? "no answer")
        // Tiles and the messages themselves, not a sentence about a number.
        XCTAssertEqual(answer?.blocks.count, 2)
    }

    func testAnEmptyTagSaysSoRatherThanGuessing() {
        let answer = makeStore().localAnswer(for: "what is in promotions")
        XCTAssertEqual(answer?.text, "Nothing is tagged Promotion right now.")
    }

    func testATagWordInAnOrdinaryQuestionIsNotATagRequest() {
        // "What did Sara say about the meeting" is for the model, not the
        // Meeting chip.
        let store = makeStore()
        XCTAssertNil(store.localAnswer(for: "What did Sara say about the meeting last week"))
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
}
