import SwiftUI
import UIKit

struct MessageDetailView: View {
    let messageID: Message.ID

    @Environment(MailStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    @State private var isReplying = false
    @State private var dictation = DictationService()
    @State private var isDrafting = false
    @State private var draftedBody: String?
    @State private var draftError: String?
    /// Latched synchronously on touch-down; see beginHold.
    @State private var isHolding = false
    @State private var htmlHeight: CGFloat = 40

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
                ComposeView(replyingTo: message, initialBody: draftedBody)
            }
        }
    }

    // MARK: - Actions

    /// Archive and delete are local to Maily for now. Changing labels in the
    /// real mailbox needs gmail.modify, which is a broader restricted scope
    /// than this app requests -- so these move the message here, not in Gmail.
    private var actionBar: some View {
        VStack(spacing: 8) {
            statusRow

            HStack(spacing: dictation.isRecording ? 0 : 6) {
                // Collapsed rather than removed while recording. Taking these
                // out of the hierarchy mid-press would change the sibling
                // layout enough to lose the drag gesture, and the release
                // would never fire.
                HStack(spacing: 6) {
                    actionButton("archivebox", "Archive") {
                        if let message { store.move(message.id, to: .archive) }
                        dismiss()
                    }
                    actionButton("ellipsis", "More") {
                        draftedBody = nil
                        isReplying = true
                    }
                    actionButton("arrowshape.turn.up.forward", "Forward") {
                        draftedBody = nil
                        isReplying = true
                    }
                }
                .frame(width: dictation.isRecording ? 0 : nil)
                .opacity(dictation.isRecording ? 0 : 1)
                .clipped()

                holdToReply
            }
            .animation(.snappy(duration: 0.22), value: dictation.isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Label on the left, secondary note on the right -- not centred.
    @ViewBuilder
    private var statusRow: some View {
        if isDrafting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Updating draft…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Applying your changes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if let problem = draftError ?? dictation.error {
            HStack {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer(minLength: 0)
            }
        }
    }

    /// Press and hold to speak, release to have it written.
    ///
    /// While held it takes the whole bar and turns red; while drafting it
    /// stays full width and reports progress. One view throughout, so the
    /// gesture is never interrupted by an identity change.
    private var holdToReply: some View {
        HStack(spacing: 8) {
            if isDrafting {
                ProgressView().tint(.white)
            } else {
                Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
            }

            Text(buttonLabel)
                .font(.subheadline.weight(.semibold))

            if dictation.isRecording {
                Text("· release to send")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: dictation.isRecording ? 54 : 46)
        .background(
            Capsule().fill(dictation.isRecording ? Color.red : Color.accentColor)
        )
        .shadow(
            color: (dictation.isRecording ? Color.red : Color.accentColor).opacity(dictation.isRecording ? 0.35 : 0),
            radius: 12
        )
        .contentShape(Capsule())
        // minimumDistance 0 fires on touch-down instead of after a drag
        // threshold, which is what "hold" has to mean.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHold() }
                .onEnded { _ in endHold() }
        )
        .disabled(isDrafting)
        .accessibilityLabel("Hold to dictate a reply")
    }

    private var buttonLabel: String {
        if isDrafting { return "Updating Draft…" }
        return dictation.isRecording ? "Recording" : "Hold to Reply"
    }

    /// onChanged fires continuously for the whole press, so this needs a
    /// synchronous latch -- `isRecording` does not flip until the audio engine
    /// is up, several events later.
    private func beginHold() {
        guard !isHolding, !isDrafting else { return }
        isHolding = true
        Task { await dictation.start() }
    }

    private func endHold() {
        guard isHolding else { return }
        isHolding = false
        dictation.stop()
        Task { await writeReply() }
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

                if let html = message.htmlBody, !html.isEmpty {
                    HTMLMessageView(html: html, height: $htmlHeight)
                        .frame(height: htmlHeight)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(message.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
