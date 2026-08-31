import SwiftUI
import UIKit

/// A label the AI assigns to a message after it reads the thread.
/// The user filters the inbox by tapping these at the top of the list.
///
/// Two families, deliberately kept in one enum so a message can carry both.
/// Priority answers "how much does this matter"; kind answers "what sort of
/// thing is it". A payment reminder due tomorrow is Very Urgent *and*
/// Finance, and filtering by either should find it.
enum AITag: String, CaseIterable, Identifiable, Codable {
    // Priority
    case urgent
    case veryImportant
    case important

    // Reply status
    case needsReply
    case noReplyNeeded

    // Kind
    case meeting
    case finance
    case security
    case newsletter
    case promotion

    var id: Self { self }

    var title: String {
        switch self {
        case .urgent:         "Very Urgent"
        case .veryImportant:  "Very Important"
        case .important:      "Important"
        case .needsReply:     "Needs Reply"
        case .noReplyNeeded:  "No Reply Needed"
        case .meeting:        "Meeting"
        case .finance:        "Finance"
        case .security:       "Security"
        case .newsletter:     "Newsletter"
        case .promotion:      "Promotion"
        }
    }

    var systemImage: String {
        switch self {
        case .urgent:         "exclamationmark.3"
        case .veryImportant:  "exclamationmark.2"
        case .important:      "exclamationmark"
        case .needsReply:     "arrowshape.turn.up.left.fill"
        case .noReplyNeeded:  "checkmark.circle.fill"
        case .meeting:        "calendar"
        case .finance:        "creditcard.fill"
        case .security:       "lock.shield.fill"
        case .newsletter:     "newspaper.fill"
        case .promotion:      "tag.fill"
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
        case .meeting:        Color(uiColor: .systemPurple)
        case .finance:        Color(uiColor: .systemTeal)
        case .security:       Color(uiColor: .systemIndigo)
        case .newsletter:     Color(uiColor: .systemBrown)
        case .promotion:      Color(uiColor: .systemPink)
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

    /// What sort of thing this is, as opposed to how much it matters. At most
    /// one of these is assigned per message.
    static let kinds: [AITag] = [.meeting, .finance, .security, .newsletter, .promotion]

    /// Maps the model's category vocabulary onto ours. Anything unrecognised
    /// -- including the model's "other" -- means no kind tag, which is the
    /// right outcome for ordinary person-to-person mail.
    static func kind(named name: String) -> AITag? {
        switch name {
        case "meeting":    .meeting
        case "finance":    .finance
        case "security":   .security
        case "newsletter": .newsletter
        case "promotion":  .promotion
        default:           nil
        }
    }
}
