import SwiftUI

/// Everything that actually needs a person, opened from the red row on the
/// inbox. Kept off the home screen itself so the summary stays one row rather
/// than reprinting the inbox above the inbox.
struct AttentionListView: View {
    @Environment(MailStore.self) private var mail

    @State private var isBulkReplying = false

    private var messages: [Message] { mail.needsAttention(limit: .max) }

    /// Two ways out of a long list: answer it, or accept it.
    private var bulkActions: some View {
        HStack(spacing: Style.tight) {
            Button {
                for message in messages { mail.markRead(message.id) }
            } label: {
                Label("Mark all read", systemImage: "envelope.open")
                    .font(Style.rowTitleStrong)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }
            .buttonStyle(.plain)

            Button {
                isBulkReplying = true
            } label: {
                Label("Reply with AI", systemImage: "sparkles")
                    .font(Style.rowTitleStrong)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Style.rowGutter)
        .padding(.vertical, Style.tight)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    var body: some View {
        List {
            Section {
                ForEach(messages) { message in
                    // View-based, not value-based. This screen is itself
                    // pushed by a view-based link, and mixing the two in one
                    // stack means the value never resolves -- tapping a row
                    // did nothing at all.
                    NavigationLink {
                        MessageDetailView(messageID: message.id)
                    } label: {
                        MessageRow(message: message, showsPriority: true, showsSummary: true)
                    }
                    .messageSwipeActions(for: message)
                }
            } footer: {
                Text("Urgent mail first, then anything waiting on a reply.")
                    .font(Style.sectionFooter)
            }
        }
        // This list is reached from the inbox and holds the same rows, so it
        // is the same kind of list. Grouped put a card and an inset around
        // mail that sits flat one screen back.
        .listStyle(.plain)
        .navigationTitle("Needs your attention")
        .navigationBarTitleDisplayMode(.inline)
        // A full-screen context, like reading a message. Leaving the tab bar
        // under the action bar stacks two chrome layers over one list.
        .hidesTabBar()
        .safeAreaInset(edge: .bottom) {
            if !messages.isEmpty { bulkActions }
        }
        .fullScreenCover(isPresented: $isBulkReplying) {
            BulkReplyFlow(messages: messages)
        }
        .overlay {
            if messages.isEmpty {
                ContentUnavailableView(
                    "All clear",
                    systemImage: "checkmark.circle.fill",
                    description: Text("Nothing is waiting on you right now.")
                )
            }
        }
    }
}

#Preview {
    NavigationStack {
        AttentionListView()
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
    }
    .environment(MailStore.connected())
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
