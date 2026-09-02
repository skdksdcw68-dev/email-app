import Foundation

/// Everything the screens read off the mailbox, worked out once.
///
/// Every number here used to be computed inside a view body, and two of them
/// inside every row of a list. The tab badge sorted the whole mailbox to
/// count unread conversations, so it ran on each tab switch and after each
/// classified email. Each message row scanned all of it to find out how big
/// its thread was, so one screen of mail was a dozen full passes per frame.
/// The AI tab asked for follow-ups three times in a single draw, and each
/// ask rebuilt every thread and then read UserDefaults once per row.
///
/// With a few thousand messages that is what made switching tabs and
/// scrolling stutter -- not the network, and not the amount of mail held.
/// It is all built once here, whenever the mail or the person's preferences
/// change, and read back as a dictionary lookup. See `MailStore.derived`.
struct MailboxIndex {

    /// Newest first, once. Every list below is a filter over this rather
    /// than its own sort.
    var sorted: [Message] = []

    /// Per mailbox, sorted and with threads collapsed: the list a screen
    /// actually shows.
    var byMailbox: [Mailbox: [Message]] = [:]

    /// Unread conversations per mailbox. What the tab badge reads.
    var unread: [Mailbox: Int] = [:]

    /// Total and unread per tag, per mailbox. What the filter chips read.
    var tagCounts: [Mailbox: MailStore.TagCounts] = [:]

    /// How many messages are in each thread, for the count on a row.
    var threadSizes: [String: Int] = [:]

    /// Conversations waiting on somebody, dismissals already taken out.
    var followUps: [FollowUp] = []

    /// Everybody who has written or been written to, with their standing.
    var people: [Person] = []

    init() {}

    init(_ messages: [Message], myAddress: String?) {
        // The one sort. Filtering below preserves order, so no list needs
        // to sort again.
        sorted = messages.sorted { $0.date > $1.date }

        for message in messages {
            if let thread = message.threadID {
                threadSizes[thread, default: 0] += 1
            }
        }

        for mailbox in Mailbox.allCases {
            let list = sorted
                .filter { mailbox.isSmart ? $0.isFlagged && $0.mailbox != .trash : $0.mailbox == mailbox }
                .collapsingThreads()
            byMailbox[mailbox] = list
            unread[mailbox] = list.filter { !$0.isRead }.count

            var counts = MailStore.TagCounts()
            for message in list {
                for tag in message.tags {
                    counts.total[tag, default: 0] += 1
                    if !message.isRead { counts.unread[tag, default: 0] += 1 }
                }
            }
            tagCounts[mailbox] = counts
        }

        guard let myAddress else { return }
        followUps = messages.followUps(myAddress: myAddress).filter {
            !FollowUpPreferences.isDismissed($0.id, lastActivity: $0.message.date)
        }
        // Assembling these walks every message and then asks the person's
        // preferences about each one. The People tab did that on every draw,
        // which meant on every keystroke in its search field.
        people = messages.people(myAddress: myAddress)
    }
}
