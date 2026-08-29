import SwiftUI
import UIKit

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

    /// Apple system colours, not fixed hex. These are dynamic -- UIKit shifts
    /// each one between light and dark mode so contrast holds in both.
    var color: Color {
        switch self {
        case .urgent:         Color(uiColor: .systemRed)
        case .veryImportant:  Color(uiColor: .systemOrange)
        case .important:      Color(uiColor: .systemYellow)
        case .needsReply:     Color(uiColor: .systemBlue)
        case .noReplyNeeded:  Color(uiColor: .systemGreen)
        }
    }

    /// Readable foreground when `color` is used as a fill. System yellow is
    /// light enough that white on it fails contrast in both modes; black holds.
    var onColor: Color {
        self == .important ? .black : .white
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
