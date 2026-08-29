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
    var preview: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
