import SwiftUI

// The AI tab itself is AIChatView now. What remains here is the canned
// question model, which still backs the starter prompts and is covered by
// tests, and the answer screen those questions resolve to.

/// One of the canned questions. Still the source of the chat starters and of
/// the tag-filtered answer screens, and covered by tests.
struct AIQuestion: Identifiable, Hashable {
    let id: String
    let prompt: String
    let symbol: String
    let tag: AITag?
    /// Shown above the results, describing what was found.
    let emptyMessage: String

    static let all: [AIQuestion] = [
        .init(id: "reply", prompt: "What do I need to reply to?", symbol: "arrowshape.turn.up.left.fill",
              tag: .needsReply, emptyMessage: "Nothing is waiting on a reply."),
        .init(id: "urgent", prompt: "What is urgent right now?", symbol: "bolt.fill",
              tag: .urgent, emptyMessage: "Nothing urgent."),
        .init(id: "important", prompt: "What matters most this week?", symbol: "flame.fill",
              tag: .veryImportant, emptyMessage: "Nothing flagged as very important."),
        .init(id: "ignore", prompt: "What can I safely ignore?", symbol: "tray.2.fill",
              tag: .noReplyNeeded, emptyMessage: "Nothing to skip."),
    ]
}

struct AIAnswerView: View {
    let question: AIQuestion

    @Environment(MailStore.self) private var mail

    private var results: [Message] {
        mail.messages(in: .inbox, tag: question.tag)
    }

    var body: some View {
        List {
            if results.isEmpty {
                ContentUnavailableView(
                    "Nothing found",
                    systemImage: "checkmark.circle.fill",
                    description: Text(question.emptyMessage)
                )
            } else {
                Section {
                    ForEach(results) { message in
                        NavigationLink(value: message.id) {
                            MessageRow(message: message)
                        }
                        .messageSwipeActions(for: message)
                    }
                } header: {
                    Text("\(results.count) \(results.count == 1 ? "message" : "messages")")
                }
            }
        }
        .navigationTitle(question.prompt)
        .navigationBarTitleDisplayMode(.inline)
        // A pushed page is a full-screen context. Leaving the tab bar under it
        // stacks two navigation systems over one screen.
        .toolbar(.hidden, for: .tabBar)
    }
}

#Preview {
    NavigationStack {
        AIAnswerView(question: AIQuestion.all[0])
    }
    .environment(MailStore.connected())
}
