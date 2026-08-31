import Foundation

struct Message: Identifiable, Hashable, Codable {
    var id = UUID()
    var sender: Contact
    var recipients: [Contact]
    var subject: String
    var body: String
    var date: Date
    var isRead: Bool = false
    var isFlagged: Bool = false
    var mailbox: Mailbox = .inbox

    /// Gmail's own identifier. `id` is a fresh UUID each fetch, so this is the
    /// only key stable enough to cache a classification against.
    var remoteID: String? = nil

    /// Gmail's conversation id. Every message in a back-and-forth shares one,
    /// which is what lets the list collapse four "Security alert" rows into a
    /// single row saying 4.
    var threadID: String? = nil

    /// The RFC 2822 Message-ID, angle brackets included. Gmail threads on its
    /// own threadId, but In-Reply-To/References is how every other client in
    /// the chain knows a reply belongs to a conversation.
    var messageIDHeader: String? = nil

    /// The sender's real HTML, kept for display. `body` stays the stripped
    /// text -- that is what classification, search and the row preview use, and
    /// none of them want markup.
    var htmlBody: String? = nil

    /// Shown as a paperclip on the row, the way every mail client marks it.
    var hasAttachment: Bool = false

    /// What the AI decided about this message.
    var tags: Set<AITag> = []
    /// One-line gist of the thread, written by the AI.
    var aiSummary: String? = nil

    /// Tags in a stable order so rows do not shuffle between redraws.
    var sortedTags: [AITag] {
        AITag.allCases.filter(tags.contains)
    }

    /// The loudest priority tag on the message, if any.
    /// `sortedTags` is already in declaration order, which is loudest-first.
    var topPriority: AITag? {
        sortedTags.first { $0.priorityRank != nil }
    }

    /// First line of the body, collapsed to a single line for the list preview.
    /// One line of actual content. Alt-text markers, tracking padding and bare
    /// URLs are stripped -- a message that opens with a logo previewed as
    /// "[image: Google]", which tells the reader nothing at all.
    var preview: String {
        GmailService.previewText(from: body)
    }

    /// Today shows a time, this week a weekday, anything older a short date --
    /// the same rule Mail.app uses.
    var listDate: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
        } else if let week = calendar.date(byAdding: .day, value: -7, to: .now), date > week {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "dd/MM/yy"
        }
        return formatter.string(from: date)
    }

    var fullDate: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension Array where Element == Message {
    /// One row per conversation, keeping the newest message of each.
    ///
    /// Four "Security alert" mails from Google are one conversation to Gmail
    /// and should be one row here. Assumes the array is already sorted
    /// newest-first, which is how every list in the app orders it.
    func collapsingThreads() -> [Message] {
        var seen = Set<String>()
        return filter { message in
            guard let thread = message.threadID else { return true }
            return seen.insert(thread).inserted
        }
    }
}
