import SwiftUI
import UIKit

struct MessageDetailView: View {
    let messageID: Message.ID

    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isReplying = false

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
        // Stated explicitly rather than relied on: reading a message should
        // never take the tab bar away.
        .toolbar(.visible, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if message != nil { actionBar }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let message {
                    Button {
                        store.toggleFlag(message.id)
                    } label: {
                        Label("Flag", systemImage: message.isFlagged ? "flag.fill" : "flag")
                    }
                    .tint(.orange)
                }
            }
        }
        .onAppear {
            store.markRead(messageID)
        }
        .sheet(isPresented: $isReplying) {
            if let message {
                ComposeView(replyingTo: message)
            }
        }
    }

    // MARK: - Actions

    /// Archive and delete are local to Maily for now. Changing labels in the
    /// real mailbox needs gmail.modify, which is a broader restricted scope
    /// than this app requests -- so these move the message here, not in Gmail.
    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton("archivebox", "Archive") {
                if let message { store.move(message.id, to: .archive) }
                dismiss()
            }

            actionButton("trash", "Delete") {
                if let message { store.delete(message.id) }
                dismiss()
            }

            actionButton("arrowshape.turn.up.forward", "Forward") {
                isReplying = true
            }

            Spacer(minLength: 8)

            Button {
                isReplying = true
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func actionButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Content

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
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    SenderAvatar(contact: message.sender, size: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.sender.name).font(.headline)
                        Text(message.sender.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(message.fullDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if message.hasAttachment {
                            Image(systemName: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
