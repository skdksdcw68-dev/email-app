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
    /// What a search turned up, when there was one. Empty otherwise: the
    /// messages retrieval handed the model are not evidence of anything and
    /// were never worth listing.
    var sources: [Message] = []
    /// An email Maily has written and is holding for the user's say-so.
    var draft: ChatDraft? = nil
    /// Shown as the thinking state until the answer lands.
    var isPending = false
    /// What Maily actually did on this turn, in order. Live while it works,
    /// kept afterwards so the path to an answer stays auditable.
    var steps: [TaskStep] = []
    var failed = false
    /// What an action actually did, once it has done it.
    var receipt: ChatReceipt? = nil
    /// What Maily went and looked for beyond the mail on this phone, when it
    /// had to. Present means the sources below are search results, and they
    /// open showing rather than folded away.
    var searchNote: String? = nil

    /// Whether the answer draws an email card or list of its own.
    var showsMessages: Bool {
        blocks.contains {
            if case .messages = $0 { return true }
            return false
        }
    }

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    static var thinking: ChatMessage {
        ChatMessage(role: .assistant, text: "", isPending: true)
    }

    static func working(_ step: TaskStep) -> ChatMessage {
        ChatMessage(role: .assistant, text: "", isPending: true, steps: [step])
    }

    static func say(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }


    static func did(_ receipt: ChatReceipt) -> ChatMessage {
        ChatMessage(role: .assistant, text: "", receipt: receipt)
    }
}

/// What an action did, shown as a card in the conversation.
///
/// The draft card already worked this way -- it appears, it shows itself
/// going, it says whether it landed -- and everything else the assistant
/// does deserves the same. An action with no visible result is one the
/// person has to go and verify by hand, which is worse than not having it.
struct ChatReceipt: Equatable, Codable {
    var symbol: String
    var title: String
    /// The caveat, when there is one. Marking read is local to Maily.
    var detail: String?
    /// What to put back if they tap Undo. Empty means there is no undo.
    var undo: [Message.ID] = []
    var isUndone = false
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
