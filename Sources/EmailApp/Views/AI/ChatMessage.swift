import Foundation

/// One turn in the AI conversation.
///
/// Codable, because conversations are now kept: `ChatHistory` writes them
/// to disk on this phone and brings them back. The transient parts --
/// pending and its label -- ride along but are never saved mid-flight.
struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable {
        case user
        case assistant
    }

    var id = UUID()
    let role: Role
    var text: String
    /// The structured parts of an answer -- stat tiles, message cards, a
    /// chart. Local answers are mostly these; model answers are mostly prose.
    var blocks: [AnswerBlock] = []
    /// The emails the answer leaned on, in the order the model cited them.
    var sources: [Message] = []
    /// An email Maily has written and is holding for the user's say-so.
    var draft: ChatDraft? = nil
    /// Shown as the thinking state until the answer lands.
    var isPending = false
    /// What the pending indicator says: "Thinking" by default, "Writing to
    /// Sara" while a draft is being produced.
    var pendingLabel: String? = nil
    var failed = false
    /// Answered on the device without touching the model -- instant and free.
    /// Marked in the UI so the user can tell the two kinds apart.
    var isLocal = false

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    static var thinking: ChatMessage {
        ChatMessage(role: .assistant, text: "", isPending: true)
    }

    static func working(_ label: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: "", isPending: true, pendingLabel: label)
    }

    static func say(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }

    static func local(_ answer: LocalAnswer) -> ChatMessage {
        ChatMessage(role: .assistant, text: answer.text, blocks: answer.blocks, isLocal: true)
    }
}

/// An email the assistant wrote, waiting in the conversation for Send.
///
/// Nothing about this is sent until the person taps the button on its card;
/// that is the whole contract of the agent. The status then tells the story
/// on the card itself: going, gone, or exactly what went wrong.
struct ChatDraft: Identifiable, Equatable, Codable {
    enum Status: Equatable, Codable {
        case ready
        case sending
        case sent
        case failed(String)
    }

    var id = UUID()
    var to: Contact
    /// Extra recipients, comma-separated, as typed in the editor.
    var cc = ""
    var subject: String
    var body: String
    /// The message this answers, when it is a reply. Threads the send.
    var replyingTo: Message?
    var status: Status = .ready
}
