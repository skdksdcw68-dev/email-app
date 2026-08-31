import SwiftUI
import UIKit

struct MessageDetailView: View {
    let messageID: Message.ID

    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isReplying = false
    @State private var htmlHeight: CGFloat = 0

    private var message: Message? { store.message(messageID) }

    /// The model is still working on this one. Keyed to this message rather
    /// than to the background pass, because opening a message now summarises
    /// it on demand -- every email that gets read gets a summary, including
    /// the bulk mail the background pass deliberately skips.
    private var isSummaryPending: Bool {
        guard let message else { return false }
        return message.aiSummary == nil && store.summarizing.contains(messageID)
    }

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
        // The reading view is a full-screen context. Leaving the tab bar under
        // an action bar stacks two chrome layers and eats the message.
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if message != nil { replyBar }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let message { optionsMenu(for: message) }
            }
        }
        .onAppear {
            store.markRead(messageID)
            Task { await store.summarize(messageID) }
        }
        .sheet(isPresented: $isReplying) {
            if let message {
                ComposeView(replyingTo: message)
            }
        }
    }

    // MARK: - Chrome

    /// Everything that is not "reply" lives behind the ellipsis. Loose archive
    /// and forward icons took up the bar without earning it -- they are one tap
    /// away here and the bar is now a single clear action.
    private func optionsMenu(for message: Message) -> some View {
        Menu {
            Button {
                store.toggleFlag(message.id)
            } label: {
                Label(message.isFlagged ? "Unflag" : "Flag",
                      systemImage: message.isFlagged ? "flag.slash" : "flag")
            }

            Button {
                store.markRead(message.id, false)
                dismiss()
            } label: {
                Label("Mark as unread", systemImage: "envelope.badge")
            }

            Button {
                isReplying = true
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.forward")
            }

            Divider()

            Button {
                store.move(message.id, to: .archive)
                dismiss()
            } label: {
                Label("Archive", systemImage: "archivebox")
            }

            Button(role: .destructive) {
                store.delete(message.id)
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                .contentShape(Circle())
        }
        // Without .plain the toolbar renders its own button background behind
        // this one, and the circle reads as two stacked shapes.
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
    }

    /// One action. Dictation lives on the reply screen, not here -- opening a
    /// message should not arm a microphone.
    private var replyBar: some View {
        Button {
            isReplying = true
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Content

    private func content(for message: Message) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(message.subject)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                senderRow(message)

                if !message.sortedTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.sortedTags) { TagBadge(tag: $0) }
                    }
                }

                if isSummaryPending {
                    summarySkeleton
                } else if let summary = message.aiSummary {
                    AISummaryCard(summary: summary)
                }

                Divider()

                body(for: message)
            }
            .padding()
        }
    }

    private func senderRow(_ message: Message) -> some View {
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

            VStack(alignment: .trailing, spacing: 3) {
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
    }

    @ViewBuilder
    private func body(for message: Message) -> some View {
        if let html = message.htmlBody, !html.isEmpty {
            ZStack(alignment: .top) {
                // The skeleton holds the space until the web view reports a
                // height, so the message does not appear as an empty gap.
                if htmlHeight == 0 { MessageSkeleton() }

                HTMLMessageView(html: html, height: $htmlHeight)
                    .frame(height: max(htmlHeight, 1))
                    .opacity(htmlHeight == 0 ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.25), value: htmlHeight == 0)
        } else if message.body.isEmpty {
            MessageSkeleton()
        } else {
            Text(message.body)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summarySkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            SkeletonLine()
            SkeletonLine(width: 180)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
        }
    }
}

private struct AISummaryCard: View {
    let summary: String
    @State private var justArrived = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AI Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A single pass over the text as it lands, so a summary that
                // appears mid-read announces itself instead of silently
                // replacing a skeleton.
                .shimmering(justArrived)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                justArrived = false
            }
        }
    }
}

#Preview {
    let store = MailStore.connected()
    return NavigationStack {
        MessageDetailView(messageID: store.messages(in: .inbox)[0].id)
    }
    .environment(store)
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
