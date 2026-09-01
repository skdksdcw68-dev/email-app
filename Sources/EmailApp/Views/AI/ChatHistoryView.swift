import SwiftUI

/// Past conversations, newest first, grouped by when they last moved.
///
/// Used two ways: pushed from the AI tab, where a row is a link that opens
/// the conversation as a page; and as a sheet over a live chat, where a row
/// hands the conversation back to the chat through `onOpen`.
struct ChatHistoryView: View {
    @Environment(ChatHistory.self) private var history

    /// Set when shown over a chat: rows call this instead of navigating.
    var onOpen: ((Conversation) -> Void)? = nil

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { conversation in
                        row(conversation)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    history.delete(conversation.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .overlay {
            if history.conversations.isEmpty {
                ContentUnavailableView(
                    "No chats yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Conversations with Maily are kept here, on this phone.")
                )
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.conversations.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            history.clearAll()
                        } label: {
                            Label("Delete all chats", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ conversation: Conversation) -> some View {
        if let onOpen {
            Button {
                onOpen(conversation)
            } label: {
                label(conversation)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AIRoute.chat(conversation.id)) {
                label(conversation)
            }
        }
    }

    private func label(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let preview = conversation.preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Today, yesterday, this week, earlier -- only the groups that have
    /// something in them.
    private var groups: [(title: String, items: [Conversation])] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now) ?? .distantPast

        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var week: [Conversation] = []
        var earlier: [Conversation] = []

        for conversation in history.conversations {
            if calendar.isDateInToday(conversation.updatedAt) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(conversation.updatedAt) {
                yesterday.append(conversation)
            } else if conversation.updatedAt > weekAgo {
                week.append(conversation)
            } else {
                earlier.append(conversation)
            }
        }

        let all: [(title: String, items: [Conversation])] = [
            ("Today", today), ("Yesterday", yesterday), ("This week", week), ("Earlier", earlier),
        ]
        return all.filter { !$0.items.isEmpty }
    }
}

#Preview {
    NavigationStack {
        ChatHistoryView()
    }
    .environment(ChatHistory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-chats.json")))
    .environment(AIMemory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-memory.json")))
}
