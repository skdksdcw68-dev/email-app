import Testing
import Foundation
@testable import EmailApp

/// Reading a conversation rather than the last message of one.
///
/// 🔴 The list has collapsed threads into a single row since the first
/// import -- four "Security alert" mails are one row -- and the reading
/// screen then showed only that one message. The rest were imported,
/// indexed and searchable, and there was no way to see them.
@MainActor
@Suite(.serialized)
struct ThreadViewTests {

    private func store(_ messages: [Message]) -> MailStore {
        let registry = MailboxRegistry.throwaway()
        let account = MailAccount(provider: .gmail, address: "me@maily.app", displayName: "me")
        registry.upsert(account)
        registry.setActive(account.id)
        let store = MailStore(account: account, registry: registry)
        store.absorb(messages)
        return store
    }

    private func message(
        _ remoteID: String,
        thread: String?,
        minutesAgo: Int,
        mailbox: Mailbox = .inbox
    ) -> Message {
        var message = Message(
            sender: Contact(name: "Sarah", address: "sarah@acme.co"),
            recipients: [Contact(name: "", address: "me@maily.app")],
            subject: "Invoice",
            body: "body \(remoteID)",
            date: Date(timeIntervalSinceNow: TimeInterval(-60 * minutesAgo))
        )
        message.remoteID = remoteID
        message.threadID = thread
        message.mailbox = mailbox
        return message
    }

    @Test func aConversationComesBackOldestFirst() {
        // Gmail puts the newest at the bottom, which is the order it
        // happened in. Newest-first makes a long thread read backwards.
        let mail = store([
            message("c", thread: "t1", minutesAgo: 1),
            message("a", thread: "t1", minutesAgo: 30),
            message("b", thread: "t1", minutesAgo: 10),
        ])
        let opened = mail.messages.first { $0.remoteID == "c" }!

        let thread = mail.thread(of: opened.id)

        #expect(thread.map(\.remoteID) == ["a", "b", "c"])
    }

    @Test func aMessageWithNoThreadIsAConversationOfOne() {
        let mail = store([message("a", thread: nil, minutesAgo: 1)])
        let opened = mail.messages[0]

        #expect(mail.thread(of: opened.id).map(\.remoteID) == ["a"])
    }

    @Test func anotherConversationIsNotPulledIn() {
        let mail = store([
            message("a", thread: "t1", minutesAgo: 5),
            message("b", thread: "t2", minutesAgo: 4),
            message("c", thread: "t1", minutesAgo: 3),
        ])
        let opened = mail.messages.first { $0.remoteID == "a" }!

        #expect(mail.thread(of: opened.id).map(\.remoteID) == ["a", "c"])
    }

    @Test func deletedMessagesAreNotPartOfWhatWasSaid() {
        let mail = store([
            message("a", thread: "t1", minutesAgo: 5),
            message("b", thread: "t1", minutesAgo: 4, mailbox: .trash),
            message("c", thread: "t1", minutesAgo: 3),
        ])
        let opened = mail.messages.first { $0.remoteID == "a" }!

        #expect(mail.thread(of: opened.id).map(\.remoteID) == ["a", "c"])
    }

    @Test func anUnsentDraftIsNotPartOfTheConversation() {
        // It would read as a message that was sent and never was.
        let mail = store([
            message("a", thread: "t1", minutesAgo: 5),
            message("d", thread: "t1", minutesAgo: 1, mailbox: .drafts),
        ])
        let opened = mail.messages.first { $0.remoteID == "a" }!

        #expect(mail.thread(of: opened.id).map(\.remoteID) == ["a"])
    }

    @Test func openingSomethingFromTrashStillShowsIt() {
        // ⚠️ The filter above must never hide the message being read. An
        // empty reading screen is worse than a conversation of one.
        let mail = store([
            message("a", thread: "t1", minutesAgo: 5),
            message("b", thread: "t1", minutesAgo: 1, mailbox: .trash),
        ])
        let opened = mail.messages.first { $0.remoteID == "b" }!

        #expect(mail.thread(of: opened.id).map(\.remoteID) == ["b"])
    }

    @Test func aMessageThatIsGoneHasNoThread() {
        let mail = store([message("a", thread: "t1", minutesAgo: 1)])

        #expect(mail.thread(of: UUID()).isEmpty)
    }

    @Test func theListStillShowsOneRowPerConversation() {
        // The other half of the same rule, and the reason the reading screen
        // had to change rather than the list.
        let messages = [
            message("c", thread: "t1", minutesAgo: 1),
            message("b", thread: "t1", minutesAgo: 10),
            message("a", thread: "t2", minutesAgo: 20),
        ]

        #expect(messages.collapsingThreads().map(\.remoteID) == ["c", "a"])
    }
}
