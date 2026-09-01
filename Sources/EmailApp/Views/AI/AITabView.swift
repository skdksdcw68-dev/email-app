import SwiftUI
import UIKit

/// Where the AI tab can go besides an email.
enum AIRoute: Hashable {
    /// A conversation: a saved one by id, or a fresh one.
    case chat(UUID?)
    /// Every saved conversation.
    case history
    /// A chase for a thread that has gone quiet, written on arrival.
    case nudge(Message.ID)
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

    /// Held here so a swipe action can push, which a NavigationLink inside
    /// one cannot do.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                briefing

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
                case .chat(let id):     AIChatView(conversationID: id)
                case .history:          ChatHistoryView()
                case .nudge(let id):    AIChatView(nudging: id)
                }
            }
            .navigationDestination(for: AIQuestion.self) { AIAnswerView(question: $0) }
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
        }
    }

    /// What is actually true this morning, counted rather than written.
    ///
    /// This used to be one sentence chosen from four by a rule, which is the
    /// kind of thing that looks like intelligence exactly once. Numbers are
    /// honest, they are free, and they are tappable.
    @ViewBuilder
    private var briefing: some View {
        let counts = mail.counts
        let quiet = mail.followUps.filter { $0.direction == .waitingOnThem }.count
        let waiting = mail.followUps.filter { $0.direction == .waitingOnYou }.count

        Section {
            if !mail.isConnected {
                Label("Connect an inbox to get started.", systemImage: "tray")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    BriefingTile(value: counts.urgent, label: "Urgent",
                                 symbol: "bolt.fill", tint: .red)
                    BriefingTile(value: waiting, label: "On you",
                                 symbol: "arrowshape.turn.up.left.fill", tint: .blue)
                    BriefingTile(value: quiet, label: "Gone quiet",
                                 symbol: "clock.arrow.circlepath", tint: .orange)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(Date.greeting)
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
    ///
    /// Split in two, because they are not the same problem and reading them
    /// as one list meant reading every row twice to work out which way round
    /// it was. "On you" is a to-do list. "Gone quiet" is the one nobody
    /// notices, because the last thing that happened is your own message and
    /// it is buried in Sent.
    @ViewBuilder
    private var followUpSection: some View {
        let followUps = mail.followUps
        let waiting = followUps.filter { $0.direction == .waitingOnYou }
        let quiet = followUps.filter { $0.direction == .waitingOnThem }

        if !waiting.isEmpty {
            Section {
                ForEach(waiting.prefix(6)) { followUp in
                    followUpRow(followUp)
                }
            } header: {
                Text("Waiting on you")
            }
        }

        if !quiet.isEmpty {
            Section {
                ForEach(quiet.prefix(6)) { followUp in
                    followUpRow(followUp)
                }
            } header: {
                Text("Gone quiet")
            } footer: {
                Text("You sent these and nobody came back. Swipe to have Maily write the chase, or to let it go.")
            }
        }
    }

    @ViewBuilder
    private func followUpRow(_ followUp: FollowUp) -> some View {
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
                    Text(followUp.message.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(followUp.direction == .waitingOnYou
                         ? "Waiting on you · \(followUp.ageDescription)"
                         : "No reply since \(followUp.ageDescription)")
                        .font(.caption2)
                        .foregroundStyle(followUp.isOverdue ? Color.orange : Color.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing) {
            Button {
                mail.dismissFollowUp(followUp.id)
            } label: {
                Label("Let it go", systemImage: "checkmark")
            }
            .tint(.green)
        }
        .swipeActions(edge: .leading) {
            if followUp.direction == .waitingOnThem {
                // A Button pushing onto the path, not a NavigationLink: a
                // link inside a swipe action does not reliably fire, and a
                // chase that silently does nothing is worse than no button.
                Button {
                    path.append(AIRoute.nudge(followUp.message.id))
                } label: {
                    Label("Nudge", systemImage: "hand.wave.fill")
                }
                .tint(.accentColor)
            }
        }
    }
}

/// One number from the briefing. Deliberately the same shape as the tiles an
/// answer draws, so the two read as the same app talking.
private struct BriefingTile: View {
    let value: Int
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(value == 0 ? Color.secondary : tint)
            Text("\(value)")
                .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(value == 0 ? Color.secondary : Color.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

#Preview {
    AITabView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(ChatHistory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-chats.json")))
    .environment(AIMemory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-memory.json")))
}
