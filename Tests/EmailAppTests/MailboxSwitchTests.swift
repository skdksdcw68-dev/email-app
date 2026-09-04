import Testing
import Foundation
@testable import EmailApp

/// Switching mailbox is the one operation in this app with no recovery.
///
/// `MailStore` keeps around ten async paths that write back into `messages`
/// when they return. A page fetched for mailbox A that lands after a switch
/// would merge A's mail into B, and then save the mixture to B's archive --
/// at which point nothing can tell which message came from where, because
/// the only record of that was the file it was saved in.
///
/// `epoch` is the fence. Every one of those paths reads it before its first
/// await and refuses to write if it moved. These check the fence itself,
/// since the paths behind it need Gmail.
@MainActor
@Suite(.serialized)
struct MailboxSwitchTests {

    private func store(_ addresses: [String]) -> MailStore {
        let registry = MailboxRegistry(defaults: .previews)
        for address in addresses {
            registry.upsert(MailAccount(provider: .gmail, address: address, displayName: address))
        }
        let first = registry.accounts[0]
        registry.setActive(first.id)
        return MailStore(account: first, registry: registry)
    }

    @Test func leavingAMailboxMovesTheFence() {
        let mail = store(["one@example.com"])
        let before = mail.epoch

        mail.leaveCurrentMailbox()

        #expect(mail.epoch != before)
        #expect(!mail.isCurrent(before), "work started before the switch must be refused")
        #expect(mail.isCurrent(mail.epoch))
    }

    @Test func leavingClearsWhatBelongedToTheOldMailbox() {
        let mail = store(["one@example.com"])
        mail.absorb([sample("a"), sample("b")])
        #expect(mail.messages.count == 2)

        mail.leaveCurrentMailbox()

        // Not "mostly cleared". A single message surviving a switch is a
        // message filed under the wrong account for ever.
        #expect(mail.messages.isEmpty)
        #expect(mail.searchResults.isEmpty)
        #expect(mail.nextPageToken == nil)
    }

    @Test func switchingPutsTheOtherMailboxInFront() async {
        let mail = store(["one@example.com", "two@example.com"])
        let second = mail.registry.accounts[1]

        await mail.activate(second)

        #expect(mail.account?.id == second.id)
        #expect(mail.registry.activeID == second.id)
        #expect(mail.messages.isEmpty)
    }

    @Test func switchingToTheOneAlreadyOpenDoesNothing() async {
        // Cheap to get wrong and expensive when it is: this would otherwise
        // clear the mailbox and reload it every time somebody tapped the row
        // they are already on.
        let mail = store(["one@example.com"])
        mail.absorb([sample("a")])
        let before = mail.epoch

        await mail.activate(mail.account!)

        #expect(mail.epoch == before)
        #expect(mail.messages.count == 1)
    }

    @Test func everySwitchMovesTheFenceAgain() async {
        let mail = store(["one@example.com", "two@example.com"])
        var seen: Set<Int> = [mail.epoch]

        await mail.activate(mail.registry.accounts[1])
        seen.insert(mail.epoch)
        await mail.activate(mail.registry.accounts[0])
        seen.insert(mail.epoch)

        // Three distinct epochs, so work from any of the three is
        // distinguishable from work started in another.
        #expect(seen.count == 3)
    }

    // MARK: - The registry

    @Test func aMailboxIsNeverAddedTwice() {
        // The id derives from the address, so connecting the same account
        // again must land on the record that is already there rather than
        // appending a second one that shadows it.
        let registry = MailboxRegistry(defaults: .previews)
        let before = registry.accounts.count

        let account = MailAccount(provider: .gmail, address: "dup@example.com", displayName: "Dup")
        registry.upsert(account)
        registry.upsert(MailAccount(provider: .gmail, address: "DUP@example.com ", displayName: "Dup Again"))

        #expect(registry.accounts.count == before + 1)
        #expect(registry.account(forAddress: "dup@example.com")?.displayName == "Dup Again")
        registry.forget(account.id)
    }

    @Test func anAddressFindsItsMailboxWhateverTheSpelling() {
        let registry = MailboxRegistry(defaults: .previews)
        let account = MailAccount(provider: .gmail, address: "Find.Me@Example.com", displayName: "F")
        registry.upsert(account)

        #expect(registry.account(forAddress: "find.me@example.com")?.id == account.id)
        #expect(registry.holds("  FIND.ME@EXAMPLE.COM  "))
        registry.forget(account.id)
    }

    private func sample(_ id: String) -> Message {
        var message = Message(
            sender: Contact(name: "Sam", address: "sam@example.com"),
            recipients: [],
            subject: id,
            body: "",
            date: .now
        )
        message.remoteID = id
        return message
    }
}

/// Auto-Reply's setup is shared across mailboxes; being armed is not.
///
/// This is the safety line. Connecting a work address to an app where
/// Auto-Reply was already on must not arm an agent to answer mail from an
/// address nobody consented to.
@MainActor
@Suite(.serialized)
struct AutoReplyActivationTests {

    private func scoped(_ address: String) -> MailboxID {
        let id = MailboxID.derive(provider: .gmail, address: address)
        MailboxScope.activate(id)
        return id
    }

    @Test func afreshMailboxIsNotArmed() {
        let id = scoped("never-asked@example.com")
        MailboxScope.purge(id)
        _ = scoped("never-asked@example.com")

        #expect(AutoReplyActivation.current == .off)
        #expect(!AutoReplyActivation.current.isOn)
        #expect(AutoReplyActivation.current.mode == .draft)

        MailboxScope.purge(id)
    }

    @Test func armingOneMailboxLeavesTheOtherAlone() {
        let work = scoped("work@example.com")
        AutoReplyActivation.current = AutoReplyActivation(
            isOn: true, mode: .send, watchingSince: .now
        )
        #expect(AutoReplyActivation.current.isOn)

        // The whole point: switching to another mailbox must not inherit it.
        let personal = scoped("personal@example.com")
        #expect(!AutoReplyActivation.current.isOn)
        #expect(AutoReplyActivation.current.mode == .draft)

        // And going back finds it exactly as it was left.
        MailboxScope.activate(work)
        #expect(AutoReplyActivation.current.isOn)
        #expect(AutoReplyActivation.current.mode == .send)

        MailboxScope.purge(work)
        MailboxScope.purge(personal)
    }

    @Test func sendingIsPerMailboxToo() {
        // A mailbox trusted to send on its own is not every mailbox.
        let trusted = scoped("trusted@example.com")
        AutoReplyActivation.current = AutoReplyActivation(isOn: true, mode: .send, watchingSince: .now)

        let other = scoped("other@example.com")
        AutoReplyActivation.current = AutoReplyActivation(isOn: true, mode: .draft, watchingSince: .now)

        MailboxScope.activate(trusted)
        #expect(AutoReplyActivation.current.mode == .send)
        MailboxScope.activate(other)
        #expect(AutoReplyActivation.current.mode == .draft)

        MailboxScope.purge(trusted)
        MailboxScope.purge(other)
    }

    @Test func watchingSinceIsPerMailbox() {
        // A newly connected account has three months of backlog. Arming it
        // against a date from months ago would work through every one.
        let old = scoped("old@example.com")
        let longAgo = Date.now.addingTimeInterval(-60 * 60 * 24 * 90)
        AutoReplyActivation.current = AutoReplyActivation(isOn: true, mode: .draft, watchingSince: longAgo)

        let fresh = scoped("fresh@example.com")
        #expect(AutoReplyActivation.current.watchingSince == nil)

        MailboxScope.purge(old)
        MailboxScope.purge(fresh)
    }
}
