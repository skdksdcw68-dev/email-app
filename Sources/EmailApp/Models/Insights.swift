import Foundation

/// The compact counts strip at the top of the inbox.
struct InboxCounts: Equatable {
    var new = 0
    var important = 0
    var needsReply = 0
    var urgent = 0

    var isCalm: Bool { urgent == 0 && needsReply == 0 }
}

/// Something Maily proactively suggests, rather than waiting to be asked.
/// Derived from the mailbox -- never hardcoded, so it stays honest.
struct Recommendation: Identifiable, Equatable {
    let id: String
    let symbol: String
    let text: String
    let actionLabel: String
    /// Filters the inbox to whatever the recommendation is about, when tapped.
    let tag: AITag?
}

/// One row of the "Your day" timeline.
struct DayItem: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String

    var time: String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// A correspondent, assembled from their messages. The People tab is about
/// relationships rather than individual emails.
struct Person: Identifiable, Equatable {
    let contact: Contact
    let conversationCount: Int
    /// Messages from them that are still tagged as needing a reply.
    let awaitingReply: Int
    let lastContacted: Date
    let isPriority: Bool

    var id: String { contact.address }

    var lastContactedDescription: String {
        let days = Calendar.current.dateComponents([.day], from: lastContacted, to: .now).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        default: return "\(days) days ago"
        }
    }
}
