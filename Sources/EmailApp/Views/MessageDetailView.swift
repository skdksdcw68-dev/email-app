import SwiftUI

struct MessageDetailView: View {
    let messageID: Message.ID

    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var message: Message? { store.message(messageID) }

    var body: some View {
        Group {
            if let message {
                content(for: message)
            } else {
                ContentUnavailableView("Message Deleted", systemImage: "trash")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let message {
                    Button {
                        store.toggleFlag(message.id)
                    } label: {
                        Label("Flag", systemImage: message.isFlagged ? "flag.fill" : "flag")
                    }
                    .tint(.orange)

                    Button(role: .destructive) {
                        store.delete(message.id)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .onAppear {
            store.markRead(messageID)
        }
    }

    private func content(for message: Message) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !message.sortedTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.sortedTags) { TagBadge(tag: $0) }
                    }
                }

                Text(message.subject)
                    .font(.title2.bold())

                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Text(message.sender.initials)
                                .font(.headline)
                                .foregroundStyle(.tint)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.sender.name).font(.headline)
                        Text("To: " + message.recipients.map(\.name).joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Text(message.fullDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let summary = message.aiSummary {
                    AISummaryCard(summary: summary)
                }

                Divider()

                Text(message.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
}

private struct AISummaryCard: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AI Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
        }
    }
}

#Preview {
    let store = MailStore.connected()
    return NavigationStack {
        MessageDetailView(messageID: store.messages(in: .inbox)[0].id)
    }
    .environment(store)
}
