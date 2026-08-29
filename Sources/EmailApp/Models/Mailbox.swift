import Foundation

enum Mailbox: String, CaseIterable, Identifiable, Codable {
    case inbox, flagged, sent, drafts, archive, trash

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox:   "Inbox"
        case .flagged: "Flagged"
        case .sent:    "Sent"
        case .drafts:  "Drafts"
        case .archive: "Archive"
        case .trash:   "Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox:   "tray.fill"
        case .flagged: "flag.fill"
        case .sent:    "paperplane.fill"
        case .drafts:  "doc.fill"
        case .archive: "archivebox.fill"
        case .trash:   "trash.fill"
        }
    }

    /// `flagged` is a saved search across every folder rather than a real folder.
    var isSmart: Bool { self == .flagged }
}
