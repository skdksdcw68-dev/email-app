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

    func testConnectPopulatesAccountAndMail() async {
        let store = MailStore()
        await store.connect()

        XCTAssertTrue(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.messages.isEmpty)
        XCTAssertFalse(store.availableTags(in: .inbox).isEmpty)
    }

    func testDisconnectClearsEverything() async {
        let store = MailStore()
        await store.connect()
        store.disconnect()

        XCTAssertFalse(store.isConnected)
        XCTAssertNil(store.account)
        XCTAssertTrue(store.messages.isEmpty)
    }

    // MARK: - Compose

    func testSendLandsInSentAsRead() {
        let store = makeStore()
        store.send(subject: "Hi", to: "a@b.com", body: "there")

        let sent = store.messages(in: .sent)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].subject, "Hi")
        XCTAssertTrue(sent[0].isRead)
    }

    func testSendWithoutSubjectGetsPlaceholder() {
        let store = makeStore()
        store.send(subject: "", to: "a@b.com", body: "body")
        XCTAssertEqual(store.messages(in: .sent)[0].subject, "(No Subject)")
    }
}
