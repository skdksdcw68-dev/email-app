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
            if let note = statusNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(dictation.isRecording ? Color.red : .secondary)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 6) {
                actionButton("archivebox", "Archive") {
                    if let message { store.move(message.id, to: .archive) }
                    dismiss()
                }

                actionButton("trash", "Delete") {
                    if let message { store.delete(message.id) }
                    dismiss()
                }

                actionButton("arrowshape.turn.up.left", "Reply") {
                    draftedBody = nil
                    isReplying = true
                }

                holdToReply
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusNote: String? {
        if dictation.isRecording { return "Recording · release to draft" }
        if isDrafting { return "Writing your reply…" }
        if let draftError { return draftError }
        if let error = dictation.error { return error }
        return nil
    }

    /// Press and hold to speak, release to have it written. A tap alone opens
    /// the normal reply sheet, so the button is never a dead end when
    /// dictation is unavailable or permission was declined.
    private var holdToReply: some View {
        HStack(spacing: 8) {
            Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                .font(.subheadline.weight(.semibold))
            Text(dictation.isRecording ? "Listening" : "Hold to Reply")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            Capsule().fill(dictation.isRecording ? Color.red : Color.accentColor)
        )
        .opacity(isDrafting ? 0.6 : 1)
        .scaleEffect(dictation.isRecording ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: dictation.isRecording)
        .contentShape(Capsule())
        // minimumDistance 0 makes this fire on touch-down rather than after a
        // drag threshold, which is what "hold" has to mean.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !dictation.isRecording, !isDrafting else { return }
                    Task { await dictation.start() }
                }
                .onEnded { _ in
                    guard dictation.isRecording else { return }
                    dictation.stop()
                    Task { await writeReply() }
                }
        )
        .disabled(isDrafting)
        .accessibilityLabel("Hold to dictate a reply")
    }

    private func writeReply() async {
        let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !spoken.isEmpty else { return }

        isDrafting = true
        draftError = nil
        defer { isDrafting = false }

        do {
            let draft = try await AIService.draft(
                replyingTo: message,
                instruction: spoken,
                tone: user.tonePreference
            )
            draftedBody = draft.body
            dictation.reset()
            isReplying = true
        } catch {
            draftError = error.localizedDescription
        }
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
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
