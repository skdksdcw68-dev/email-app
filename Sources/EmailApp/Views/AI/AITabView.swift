import SwiftUI
import UIKit

/// Where the AI tab can go besides an email.
enum AIRoute: Hashable {
    /// A conversation: a saved one by id, or a fresh one.
    case chat(UUID?)
    /// Every saved conversation.
    case history
}

/// The AI tab. A briefing, a way into the chat, what is outstanding, and
/// the conversations you have already had.
///
/// The chat is pushed from here rather than being the tab itself: this screen
/// is the standing view of the mailbox, and a conversation about it is
/// something you go into and come back from.
struct AITabView: View {
    @Environment(MailStore.self) private var mail
    @Environment(ChatHistory.self) private var history

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Today", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(mail.inboxStatus)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Daily briefing")
                }

                Section {
                    // Value-based, like every other link in this stack. A
                    // view-based push here and value-based pushes inside the
                    // chat cannot share one path: tapping an email card from
                    // the chat replaced the chat instead of stacking on it,
                    // and Back skipped straight over it.
                    NavigationLink(value: AIRoute.chat(nil)) {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                                .font(.body)
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Talk to Maily")
                                    .font(.subheadline.weight(.semibold))
                                Text("Ask anything about your email.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                recentChats

                followUpSection

                Section("Quick questions") {
                    ForEach(AIQuestion.all) { question in
                        NavigationLink(value: question) {
                            HStack(spacing: 12) {
                                Image(systemName: question.symbol)
                                    .font(.body)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.tint)
                                    .frame(width: 26)
                                Text(question.prompt)
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("AI")
            .navigationDestination(for: AIRoute.self) { route in
                switch route {
                case .chat(let id): AIChatView(conversationID: id)
                case .history:      ChatHistoryView()
                }
            }
            .navigationDestination(for: AIQuestion.self) { AIAnswerView(question: $0) }
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
        }
    }

    /// The last few conversations, so picking one up is one tap from here.
    @ViewBuilder
    private var recentChats: some View {
        let recent = history.conversations
        if !recent.isEmpty {
            Section {
                ForEach(recent.prefix(4)) { conversation in
                    NavigationLink(value: AIRoute.chat(conversation.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if recent.count > 4 {
                    NavigationLink(value: AIRoute.history) {
                        Label("All chats", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                    }
                }
            } header: {
                Text("Recent chats")
            }
        }
    }

    /// The thing a normal inbox cannot tell you: what has gone quiet.
    @ViewBuilder
    private var followUpSection: some View {
        let followUps = mail.followUps
        if !followUps.isEmpty {
            Section {
                ForEach(followUps.prefix(8)) { followUp in
                    NavigationLink(value: followUp.message.id) {
                        HStack(spacing: 12) {
                            Image(systemName: followUp.direction == .waitingOnYou
                                  ? "arrowshape.turn.up.left.fill"
                                  : "clock.arrow.circlepath")
                                .font(.footnote)
                                .foregroundStyle(followUp.isOverdue ? Color.orange : Color.secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(followUp.message.sender.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(followUp.direction == .waitingOnYou
                                     ? "Waiting on you · \(followUp.ageDescription)"
                                     : "No reply since \(followUp.ageDescription)")
                                    .font(.caption)
                                    .foregroundStyle(followUp.isOverdue ? Color.orange : Color.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Follow-ups")
            } footer: {
                Text("Conversations where somebody is still waiting.")
            }
        }
    }
}

#Preview {
    AITabView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(ChatHistory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-chats.json")))
    .environment(AIMemory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-memory.json")))
}
