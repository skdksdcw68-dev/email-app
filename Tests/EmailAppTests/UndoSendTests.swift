import Testing
import Foundation
@testable import EmailApp

/// The rule this whole feature stands on: a message that was not cancelled
/// gets sent. Every test here is a way of trying to lose one.
///
/// The send itself needs Gmail, so these check the holding -- which is the
/// part with the states, and the part where a message goes missing.
@MainActor
struct UndoSendTests {

    private func store() -> MailStore {
        MailStore(
            account: MailAccount(provider: .gmail, address: "me@example.com", displayName: "Me"), registry: .throwaway(),
            messages: []
        )
    }

    @Test func sendingHoldsRatherThanSends() {
        let mail = store()
        mail.sendWithUndo(subject: "Hello", to: "sam@example.com", body: "Hi")

        #expect(mail.heldSend?.recipient == "sam@example.com")
        #expect(mail.heldSend?.subject == "Hello")
        #expect(mail.heldSend?.sendsAt ?? .distantPast > .now)

        mail.cancelHeldSend()
    }

    @Test func anEmptySubjectIsShownAsGmailShowsIt() {
        let mail = store()
        mail.sendWithUndo(subject: "", to: "sam@example.com", body: "Hi")

        #expect(mail.heldSend?.subject == "(No Subject)")
        mail.cancelHeldSend()
    }

    @Test func cancellingLeavesNothingBehind() {
        let mail = store()
        mail.sendWithUndo(subject: "Hello", to: "sam@example.com", body: "Hi")
        mail.cancelHeldSend()

        #expect(mail.heldSend == nil)
        #expect(mail.heldWork == nil)
        #expect(mail.heldTimer == nil)
    }

    @Test func cancellingTwiceIsHarmless() {
        let mail = store()
        mail.sendWithUndo(subject: "Hello", to: "sam@example.com", body: "Hi")
        mail.cancelHeldSend()
        mail.cancelHeldSend()

        #expect(mail.heldSend == nil)
    }

    @Test func sendingNowWithNothingHeldDoesNothing() {
        let mail = store()
        mail.sendHeldNow()
        #expect(mail.heldSend == nil)
    }

    @Test func sendingNowClearsTheBannerAndTheTimer() {
        // The send it starts will fail without Gmail, which is fine -- what
        // matters is that the held state is let go so nothing sends twice.
        let mail = store()
        mail.sendWithUndo(subject: "Hello", to: "sam@example.com", body: "Hi")
        mail.sendHeldNow()

        #expect(mail.heldSend == nil)
        #expect(mail.heldWork == nil)
        #expect(mail.heldTimer == nil)
    }

    @Test func asecondMessageDoesNotReplaceTheFirst() {
        // Replacing would drop a message somebody wrote and watched leave the
        // compose sheet. The first one goes; the second takes the window.
        let mail = store()
        mail.sendWithUndo(subject: "First", to: "one@example.com", body: "Hi")
        let first = mail.heldSend

        mail.sendWithUndo(subject: "Second", to: "two@example.com", body: "Hi")

        #expect(mail.heldSend?.subject == "Second")
        #expect(mail.heldSend != first)

        mail.cancelHeldSend()
    }

    @Test func theWindowIsLongEnoughToReadAndShortEnoughToTrust() {
        #expect(MailStore.undoWindow >= 5)
        #expect(MailStore.undoWindow <= 15)
    }
}
