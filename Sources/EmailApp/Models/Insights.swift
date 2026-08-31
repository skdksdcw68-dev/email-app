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
