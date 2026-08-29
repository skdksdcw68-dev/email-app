import SwiftUI

/// A label the AI assigns to a message after it reads the thread.
/// The user filters the inbox by tapping these at the top of the list.
enum AITag: String, CaseIterable, Identifiable, Codable {
    case urgent
    case veryImportant
    case important
    case needsReply
    case noReplyNeeded

    var id: Self { self }

    var title: String {
        switch self {
        case .urgent:         "Very Urgent"
        case .veryImportant:  "Very Important"
        case .important:      "Important"
        case .needsReply:     "Needs Reply"
        case .noReplyNeeded:  "No Reply Needed"
        }
    }

    var systemImage: String {
        switch self {
        case .urgent:         "exclamationmark.3"
        case .veryImportant:  "exclamationmark.2"
        case .important:      "exclamationmark"
        case .needsReply:     "arrowshape.turn.up.left.fill"
        case .noReplyNeeded:  "checkmark.circle.fill"
        }
    }

    /// Deliberately darker than the system colours -- these are drawn as text on
    /// a tinted capsule, and `.yellow` on light yellow is unreadable.
    var color: Color {
        switch self {
        case .urgent:         Color(red: 0.84, green: 0.16, blue: 0.16)
        case .veryImportant:  Color(red: 0.87, green: 0.45, blue: 0.05)
        case .important:      Color(red: 0.72, green: 0.53, blue: 0.04)
        case .needsReply:     Color(red: 0.11, green: 0.42, blue: 0.85)
        case .noReplyNeeded:  Color(red: 0.13, green: 0.55, blue: 0.33)
        }
    }

    /// How loud the tag is. Lower sorts first; `nil` means it says nothing
    /// about urgency. Unused by the list today, but this is the hook for
    /// "sort by priority instead of date" later.
    var priorityRank: Int? {
        switch self {
        case .urgent:        0
        case .veryImportant: 1
        case .important:     2
        default:             nil
        }
    }
}
