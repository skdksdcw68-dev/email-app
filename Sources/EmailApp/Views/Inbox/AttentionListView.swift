import SwiftUI

/// Everything that actually needs a person, opened from the red row on the
/// inbox. Kept off the home screen itself so the summary stays one row rather
/// than reprinting the inbox above the inbox.
struct AttentionListView: View {
    @Environment(MailStore.self) private var mail

    private var messages: [Message] { mail.needsAttention(limit: .max) }

    var body: some View {
        List {
            Section {
                ForEach(messages) { message in
                    NavigationLink(value: message.id) {
                        AttentionRow(message: message)
                    }
                    .messageSwipeActions(for: message)
                }
            } footer: {
                Text("Urgent mail first, then anything waiting on a reply.")
            }
        }
        .navigationTitle("Needs your attention")
        .navigationBarTitleDisplayMode(.inline)
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

private struct AttentionRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let priority = message.topPriority {
                    TagBadge(tag: priority)
                }
                Text(message.sender.name)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                Text(message.listDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(message.subject)
                .font(.subheadline)
                .lineLimit(1)

            Text(message.aiSummary ?? message.preview)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}

#Preview {
    NavigationStack {
        AttentionListView()
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
    }
    .environment(MailStore.connected())
}
