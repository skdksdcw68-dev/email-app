import Testing
import Foundation
@testable import EmailApp

/// Who owns a connected mailbox: the Maily account, or the phone?
///
/// 🔴 It was the phone, by accident. Signing out of Maily called
/// `disconnect()`, which takes the mailbox in front of you and then *promotes
/// the next one*. Abel signed out, signed back in, and was met by his other
/// account's mail -- already imported, already sorted -- under a Maily account
/// that no longer existed on the device.
@MainActor
@Suite(.serialized)
struct AccountTeardownTests {

    private func store(_ addresses: [String]) -> MailStore {
        let registry = MailboxRegistry.throwaway()
        for address in addresses {
            registry.upsert(MailAccount(provider: .gmail, address: address, displayName: address))
        }
        let first = registry.accounts[0]
        registry.setActive(first.id)
        return MailStore(account: first, registry: registry)
    }

    @Test func disconnectingTakesOnlyTheMailboxInFrontOfYou() {
        // The behaviour `disconnectEverything` is built on top of, pinned
        // here so a change to it is a deliberate one.
        let mail = store(["one@example.com", "two@example.com"])

        mail.disconnect()

        #expect(mail.registry.accounts.count == 1)
        #expect(mail.account?.address == "two@example.com", "the next one comes forward")
    }

    @Test func signingOutOfMailyForgetsEveryMailbox() {
        let mail = store(["one@example.com", "two@example.com", "three@example.com"])

        mail.disconnectEverything()

        #expect(mail.registry.accounts.isEmpty)
        #expect(mail.account == nil)
        #expect(mail.registry.opening == nil, "nothing is left to open on the next launch")
    }

    @Test func signingOutWithOneMailboxIsTheSameRule() {
        let mail = store(["only@example.com"])

        mail.disconnectEverything()

        #expect(mail.registry.accounts.isEmpty)
        #expect(mail.account == nil)
    }

    @Test func signingOutWithNothingConnectedDoesNothingAndDoesNotHang() {
        let registry = MailboxRegistry.throwaway()
        let mail = MailStore(account: nil, registry: registry)

        mail.disconnectEverything()

        #expect(mail.registry.accounts.isEmpty)
    }

    @Test func aMailboxTheActivePointerNeverReachedGoesToo() {
        // A record saved by a build that died before it was made active. The
        // loop over `disconnect()` cannot see it, so the sweep afterwards
        // must.
        let mail = store(["one@example.com"])
        mail.registry.upsert(
            MailAccount(provider: .imap, address: "stranded@example.com", displayName: "stranded")
        )

        mail.disconnectEverything()

        #expect(mail.registry.accounts.isEmpty)
    }
}
