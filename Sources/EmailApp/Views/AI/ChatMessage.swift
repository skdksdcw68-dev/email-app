import Foundation

/// One turn in the AI conversation.
///
/// Kept in memory for the session rather than persisted. A chat about "what
/// needs my attention today" is worthless tomorrow, and storing every answer
/// would mean storing a running summary of somebody's mail on disk for no
/// benefit.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    /// The structured parts of an answer -- stat tiles, message cards, a
    /// chart. Local answers are mostly these; model answers are mostly prose.
    var blocks: [AnswerBlock] = []
    /// The emails the answer leaned on, in the order the model cited them.
    var sources: [Message] = []
    /// Shown as the thinking state until the answer lands.
    var isPending = false
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

    static func local(_ answer: LocalAnswer) -> ChatMessage {
        ChatMessage(role: .assistant, text: answer.text, blocks: answer.blocks, isLocal: true)
    }
}
