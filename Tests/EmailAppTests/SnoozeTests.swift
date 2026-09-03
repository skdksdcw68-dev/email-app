import Testing
import Foundation
@testable import EmailApp

/// Snoozing is the one feature that hides mail, so the tests are mostly about
/// it coming back. A message that goes away and stays away is worse than one
/// that never left.
@Suite(.serialized)
struct SnoozeTests {

    init() { SnoozeStore.clearAll() }

    @Test func aSnoozedMessageIsAsleepUntilItsDay() {
        let later = Date.now.addingTimeInterval(3600)
        SnoozeStore.snooze("m1", until: later)

        #expect(SnoozeStore.isAsleep("m1"))
        #expect(SnoozeStore.wakesAt("m1") == later)
    }

    @Test func itWakesOnItsOwnWithoutAnythingRunning() {
        // The comparison is the whole mechanism: a phone that was off all
        // night still shows the right thing on the first draw.
        let past = Date.now.addingTimeInterval(-60)
        SnoozeStore.snooze("m1", until: past)

        #expect(!SnoozeStore.isAsleep("m1"))
        #expect(SnoozeStore.wakesAt("m1") == nil)
        #expect(SnoozeStore.sleeping().isEmpty)
    }

    @Test func nothingUnknownIsAsleep() {
        #expect(!SnoozeStore.isAsleep("never-snoozed"))
        #expect(!SnoozeStore.isAsleep(nil))
    }

    @Test func wakingBringsItBackEarly() {
        SnoozeStore.snooze("m1", until: .now.addingTimeInterval(3600))
        SnoozeStore.wake("m1")
        #expect(!SnoozeStore.isAsleep("m1"))
    }

    @Test func sleepingIsOrderedByWhenItComesBack() {
        SnoozeStore.snooze("later", until: .now.addingTimeInterval(7200))
        SnoozeStore.snooze("sooner", until: .now.addingTimeInterval(600))

        #expect(SnoozeStore.sleeping().map(\.id) == ["sooner", "later"])
    }

    @Test func forgettingReportsWhetherAnythingCameBack() {
        SnoozeStore.snooze("gone", until: .now.addingTimeInterval(-60))
        SnoozeStore.snooze("staying", until: .now.addingTimeInterval(3600))

        #expect(SnoozeStore.forgetWoken())
        // Nothing expired the second time, so nothing to report.
        #expect(!SnoozeStore.forgetWoken())
        #expect(SnoozeStore.isAsleep("staying"))
    }

    // MARK: - When

    @Test func everyChoiceLandsInTheFuture() {
        let now = Date.now
        for when in SnoozeStore.When.allCases {
            #expect(when.date(from: now) > now, "\(when) is not in the future")
        }
    }

    @Test func tomorrowIsAMorningNotAMidnight() {
        // A message that comes back at 00:01 is a message you meet at the
        // bottom of the inbox having missed it.
        let date = SnoozeStore.When.tomorrow.date(from: .now)
        #expect(Calendar.current.component(.hour, from: date) == 8)
    }

    @Test func laterTodayIsHoursNotDays() {
        let now = Date.now
        let date = SnoozeStore.When.laterToday.date(from: now)
        #expect(date.timeIntervalSince(now) < 60 * 60 * 4)
    }

    // MARK: - The inbox

    /// The sample mailbox carries no Gmail ids, and snoozing is keyed on
    /// them, so these build their own.
    @MainActor
    private func store(with mailboxes: [(String, Mailbox)]) -> MailStore {
        let messages = mailboxes.enumerated().map { index, pair -> Message in
            var message = Message(
                sender: Contact(name: "Sam", address: "sam@example.com"),
                recipients: [Contact(name: "Me", address: "me@example.com")],
                subject: "Subject \(index)",
                body: "Body",
                date: Date.now.addingTimeInterval(TimeInterval(-index * 60)),
                mailbox: pair.1
            )
            message.remoteID = pair.0
            return message
        }
        return MailStore(
            account: GmailAccount(email: "me@example.com", displayName: "Me", connectedAt: .now),
            messages: messages
        )
    }

    @MainActor
    @Test func snoozedMailLeavesTheInboxAndItsCounts() {
        let mail = store(with: [("a", .inbox), ("b", .inbox), ("c", .inbox)])
        #expect(mail.messages(in: .inbox).count == 3)

        SnoozeStore.snooze("b", until: .now.addingTimeInterval(3600))
        mail.notePreferencesChanged()

        let after = mail.messages(in: .inbox)
        #expect(after.count == 2)
        #expect(!after.contains { $0.remoteID == "b" })

        // Still held, still searchable, still openable -- only hidden.
        #expect(mail.messages.contains { $0.remoteID == "b" })
    }

    @MainActor
    @Test func wakingPutsItBack() {
        let mail = store(with: [("a", .inbox), ("b", .inbox)])

        SnoozeStore.snooze("b", until: .now.addingTimeInterval(-60))
        mail.wakeSnoozed()

        #expect(mail.messages(in: .inbox).count == 2)
    }

    @MainActor
    @Test func snoozingDoesNotHideItFromSent() {
        // The filter is the inbox only. Hiding a message from Sent because it
        // was snoozed would be nonsense.
        let mail = store(with: [("a", .sent)])

        SnoozeStore.snooze("a", until: .now.addingTimeInterval(3600))
        mail.notePreferencesChanged()

        #expect(mail.messages(in: .sent).contains { $0.remoteID == "a" })
    }

    @MainActor
    @Test func mailWithNoGmailIdIsNeverHidden() {
        // Nothing this app wrote itself has a remote id yet, and none of it
        // should vanish because somebody snoozed something else.
        let mail = MailStore(
            account: GmailAccount(email: "me@example.com", displayName: "Me", connectedAt: .now),
            messages: [Message(
                sender: Contact(name: "Sam", address: "sam@example.com"),
                recipients: [],
                subject: "No id",
                body: "",
                date: .now
            )]
        )
        SnoozeStore.snooze("something-else", until: .now.addingTimeInterval(3600))
        mail.notePreferencesChanged()

        #expect(mail.messages(in: .inbox).count == 1)
    }
}
