import Foundation
import UIKit

/// What people do with Maily: who signs up, what they come back for, what
/// they ask the assistant about, and where it lets them down.
///
/// Shape, never content. An event says a question was 42 characters long,
/// needed the mailbox, retrieved nine emails and took 3.1 seconds; it does
/// not say what was asked or who it was about. That is a deliberate line and
/// not only a polite one: Maily holds Gmail's restricted scopes, and their
/// Limited Use terms are specific about where mail content may and may not
/// end up. Counting how the app is used is squarely inside them. Copying the
/// mail into a second table to look at later is not.
///
/// Fire and forget. Nothing here blocks a view, nothing here throws into the
/// UI, and every call is a no-op when the person is signed out or has turned
/// it off. An analytics call that can break the app is not worth having.
enum Analytics {

    // MARK: - Recording

    static func record(_ name: Event, _ properties: [String: Value] = [:]) {
        guard AppSettings.sharesUsageData else { return }

        var payload = properties
        payload["platform"] = .string("ios")
        payload["os"] = .string(UIDevice.current.systemVersion)
        payload["app"] = .string(Bundle.main.version)

        Task.detached(priority: .background) {
            try? await write(name.rawValue, payload)
        }
    }

    /// Sign-up and sign-in, which is the "who uses it" half of the question.
    static func recordSignIn(provider: AppAccount.Provider, isNew: Bool) {
        record(isNew ? .signedUp : .signedIn, ["provider": .string(provider.rawValue)])
    }

    private static func write(_ name: String, _ properties: [String: Value]) async throws {
        let row = Row(
            user_id: try await Backend.userID(),
            name: name,
            properties: properties
        )
        try await Backend.upsert("events", [row])
    }

    private struct Row: Encodable {
        let user_id: UUID
        let name: String
        let properties: [String: Value]
    }

    // MARK: - Events

    enum Event: String {
        case appOpened = "app_opened"
        case signedUp = "signed_up"
        case signedIn = "signed_in"
        case mailboxConnected = "mailbox_connected"

        /// The interesting one: what people bring to the assistant.
        case chatAsked = "chat_asked"
        case chatStopped = "chat_stopped"
        case chatFailed = "chat_failed"

        case draftWritten = "draft_written"
        case draftSent = "draft_sent"
        case draftEdited = "draft_edited"
        case draftDiscarded = "draft_discarded"

        case markedRead = "marked_read"
        case markedReadUndone = "marked_read_undone"
        case memorySaved = "memory_saved"
        /// Auto-Reply setup finished. Shape of the setup only -- never the
        /// business facts, which are the person's own and stay on the phone.
        case autoReplySetUp = "auto_reply_set_up"
        /// The second tier found something in a message. Count and
        /// direction only; never what it found.
        case factsExtracted = "facts_extracted"

        case bulkReplyFinished = "bulk_reply_finished"
        case tagFiltered = "tag_filtered"
        case searchUsed = "search_used"
    }

    // MARK: - Values

    /// Only the three shapes an event property is allowed to be. A `String`
    /// case exists for labels like a provider or a tag name, never for
    /// anything somebody typed.
    enum Value: Encodable {
        case string(String)
        case int(Int)
        case bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value):    try container.encode(value)
            case .bool(let value):   try container.encode(value)
            }
        }
    }
}

extension Bundle {
    var version: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
