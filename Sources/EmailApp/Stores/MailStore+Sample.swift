import Foundation

extension Message {
    /// Stand-in for a first Gmail sync, already tagged as if the AI had run.
    static var samples: [Message] {
        let now = Date.now
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        let finance = Contact(name: "Yohannes Tesfaye", address: "yohannes@northbridge.co")
        let recruiter = Contact(name: "Liya Girma", address: "liya@talentloop.io")
        let sara = Contact(name: "Sara Bekele", address: "sara@example.com")
        let dawit = Contact(name: "Dawit Haile", address: "dawit@example.com")
        let apple = Contact(name: "Apple Developer", address: "no-reply@apple.com")
        let github = Contact(name: "GitHub", address: "noreply@github.com")
        let digest = Contact(name: "Design Weekly", address: "hello@designweekly.com")

        return [
            Message(
                sender: finance,
                recipients: [.me],
                subject: "Wire transfer needs your approval before 5pm",
                body: """
                The vendor payment is sitting in the queue and the bank cuts off
                at 5pm today. I need your sign-off on the amount before then or
                it rolls to Monday, which puts us past the contract date.

                Amount: 42,500. Same account as last quarter.
                """,
                date: ago(0.6),
                mailbox: .inbox,
                tags: [.urgent, .needsReply],
                aiSummary: "Hard 5pm deadline. Yohannes needs your approval on a 42,500 vendor wire or it slips past the contract date."
            ),
            Message(
                sender: sara,
                recipients: [.me],
                subject: "Re: design review on Thursday",
                body: """
                Thursday at 2 works for me. I pushed the latest mockups to the
                shared folder -- have a look at the compose sheet before we meet,
                I changed how the recipient field behaves.
                """,
                date: ago(3),
                isFlagged: true,
                mailbox: .inbox,
                tags: [.veryImportant, .needsReply],
                aiSummary: "Sara confirmed Thursday 2pm and wants you to review the compose-sheet mockups beforehand."
            ),
            Message(
                sender: recruiter,
                recipients: [.me],
                subject: "iOS role -- are you open to a chat this week?",
                body: """
                I came across your work and wanted to reach out about a senior
                iOS position. Fully remote, and the team is small. Would you be
                open to a short call Wednesday or Thursday?
                """,
                date: ago(9),
                mailbox: .inbox,
                tags: [.important, .needsReply],
                aiSummary: "Recruiter asking for a call Wednesday or Thursday about a remote senior iOS role."
            ),
            Message(
                sender: apple,
                recipients: [.me],
                subject: "Your app is ready for testing",
                body: """
                Mail 1.0 (14) is now available to your internal testers in
                TestFlight. This build will expire in 90 days.
                """,
                date: ago(20),
                isRead: true,
                mailbox: .inbox,
                tags: [.important, .noReplyNeeded],
                aiSummary: "Build 14 finished processing and is live for internal testers. Expires in 90 days."
            ),
            Message(
                sender: dawit,
                recipients: [.me],
                subject: "Lunch on Friday?",
                body: "There is a new place near the office. Are you free around 1?",
                date: ago(28),
                isFlagged: true,
                mailbox: .inbox,
                tags: [.needsReply],
                aiSummary: "Dawit is asking if you are free for lunch Friday around 1."
            ),
            Message(
                sender: github,
                recipients: [.me],
                subject: "[email-app] 2 new commits pushed to main",
                body: """
                abelamare pushed 2 commits to main:

                  3f9a1c2  chore: pin Xcode version in codemagic.yaml
                  8b40de7  fix: unread badge counted trashed mail
                """,
                date: ago(30),
                isRead: true,
                mailbox: .inbox,
                tags: [.noReplyNeeded],
                aiSummary: "Automated push notification. Nothing needs your attention."
            ),
            Message(
                sender: digest,
                recipients: [.me],
                subject: "This week in design systems",
                body: "Five links, one long read, and a job board. Unsubscribe any time.",
                date: ago(44),
                isRead: true,
                mailbox: .inbox,
                tags: [.noReplyNeeded],
                aiSummary: "Weekly newsletter. Safe to skim or archive."
            ),
            Message(
                sender: .me,
                recipients: [sara],
                subject: "Notes from standup",
                body: "Sending over what we covered so you have it before Thursday.",
                date: ago(26),
                isRead: true,
                mailbox: .sent,
                tags: [.noReplyNeeded]
            ),
            Message(
                sender: .me,
                recipients: [dawit],
                subject: "(No Subject)",
                body: "Hey -- ",
                date: ago(5),
                isRead: true,
                mailbox: .drafts
            ),
        ]
    }
}

extension MailStore {
    /// A store that is already connected. Previews only.
    static func connected() -> MailStore {
        MailStore(
            account: MailAccount(
                provider: .gmail,
                address: "abelamare1633@gmail.com",
                displayName: "Abel Amare"
            ),
            // Its own registry, in its own suite. A preview or a test must
            // never write into the real one.
            registry: MailboxRegistry(defaults: .previews),
            messages: Message.samples
        )
    }
}
