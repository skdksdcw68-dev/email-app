import XCTest
@testable import EmailApp

@MainActor
final class ChatHistoryTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "chats-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func conversation(_ title: String, turns: [ChatMessage], updated: Date = .now) -> Conversation {
        Conversation(title: title, createdAt: updated, updatedAt: updated, turns: turns)
    }

    func testASavedConversationComesBackAfterReload() {
        let history = ChatHistory(fileURL: fileURL)
        history.save(conversation("Hi", turns: [.user("Hi"), .say("Hey.")]))

        let reloaded = ChatHistory(fileURL: fileURL)
        XCTAssertEqual(reloaded.conversations.count, 1)
        XCTAssertEqual(reloaded.conversations.first?.turns.map(\.text), ["Hi", "Hey."])
    }

    func testStructuredAnswersSurviveTheRoundTrip() {
        // An answer can be tiles and cards, not only prose. They must come
        // back as they were, or the history shows a caption above nothing.
        let stats = Stat(title: "Urgent", value: "3", symbol: "bolt.fill", tint: .red)
        var answer = ChatMessage.say("Where things stand:")
        answer.blocks = [.stats([stats])]
        let history = ChatHistory(fileURL: fileURL)
        history.save(conversation("Urgent?", turns: [.user("Urgent?"), answer]))

        let reloaded = ChatHistory(fileURL: fileURL)
        XCTAssertEqual(reloaded.conversations.first?.turns.last?.blocks, [.stats([stats])])
    }

    func testSavingAgainReplacesRatherThanDuplicates() {
        let history = ChatHistory(fileURL: fileURL)
        var chat = conversation("Hi", turns: [.user("Hi")])
        history.save(chat)
        chat.turns.append(.say("Hey."))
        history.save(chat)

        XCTAssertEqual(history.conversations.count, 1)
        XCTAssertEqual(history.conversations.first?.turns.count, 2)
    }

    func testNewestComesFirst() {
        let history = ChatHistory(fileURL: fileURL)
        history.save(conversation("Old", turns: [.user("Old")], updated: .now.addingTimeInterval(-3600)))
        history.save(conversation("New", turns: [.user("New")]))

        XCTAssertEqual(history.conversations.map(\.title), ["New", "Old"])
    }

    func testDeleteRemovesIt() {
        let history = ChatHistory(fileURL: fileURL)
        let chat = conversation("Hi", turns: [.user("Hi")])
        history.save(chat)
        history.delete(chat.id)

        XCTAssertTrue(history.conversations.isEmpty)
        XCTAssertTrue(ChatHistory(fileURL: fileURL).conversations.isEmpty)
    }

    func testTitleComesFromTheFirstQuestion() {
        XCTAssertEqual(Conversation.title(for: [.user("What needs a reply?"), .say("Two things.")]), "What needs a reply?")
        XCTAssertEqual(Conversation.title(for: []), "New chat")
    }

    func testDisconnectingTheMailboxClearsHistory() async {
        let history = ChatHistory(fileURL: fileURL)
        history.save(conversation("Hi", turns: [.user("Hi")]))

        NotificationCenter.default.post(name: .mailboxDisconnected, object: nil)

        // Delivered on the main queue, then hopped to the main actor: two
        // turns of the loop at most. Poll briefly rather than guess the count.
        for _ in 0..<20 where !history.conversations.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertTrue(history.conversations.isEmpty)
    }
}
