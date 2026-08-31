import SwiftUI
import UIKit

/// Drafts a reply to every message that needs one, then shows them for
/// approval one at a time.
///
/// Nothing is sent by pressing Generate. Every draft is listed and editable
/// first, and can then be sent one at a time or all at once. The send-all
/// button confirms and names its recipients, because sending mail is the only
/// action in this app that cannot be taken back.
struct BulkReplyView: View {
    let messages: [Message]

    @Environment(MailStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    @State private var style: WriterStyle = .short
    @State private var customPrompt = ""
    @State private var drafts: [PendingReply] = []
    @State private var generated = 0
    @State private var isWorking = false
    @State private var isSending = false
    @State private var isConfirmingSendAll = false
    @State private var sentCount = 0
    @State private var sendTarget = 0
    @State private var errorMessage: String?

    struct PendingReply: Identifiable {
        let id: Message.ID
        let message: Message
        var body: String
        var isSent = false
        var failure: String?
    }

    private var eligible: [Message] {
        // Bulk mail does not get a reply written for it.
        messages.filter { !$0.tags.contains(.noReplyNeeded) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    setup
                } else {
                    review
                }
            }
            .navigationTitle(drafts.isEmpty ? "Reply with AI" : "Review replies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(drafts.isEmpty ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(eligible.count) \(eligible.count == 1 ? "reply" : "replies") to write")
                        .font(.title3.weight(.bold))
                    Text("Maily writes a draft for each one. You review them all first — nothing is sent from this screen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Style")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(WriterStyle.allCases.filter { $0 != .polish }) { option in
                            chip(option)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Anything to say in all of them?")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("I'm travelling this week, will reply properly on Monday", text: $customPrompt, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(2...4)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await generateAll() }
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView().tint(.white)
                        Text("Writing \(generated) of \(eligible.count)…")
                    } else {
                        Image(systemName: "sparkles")
                        Text("Write \(eligible.count) drafts")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(eligible.isEmpty ? Color.secondary : Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(isWorking || eligible.isEmpty)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func chip(_ option: WriterStyle) -> some View {
        let isSelected = style == option
        return Button {
            withAnimation(.snappy(duration: 0.18)) { style = option }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: option.systemImage).font(.caption.weight(.semibold))
                Text(option.title).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Review

    private var unsent: [PendingReply] {
        drafts.filter { !$0.isSent && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One button for the lot, plus per-draft send for anything you want to
    /// handle yourself. It confirms first and names the recipients: this is
    /// the only action in the app that cannot be taken back.
    private var sendAllBar: some View {
        VStack(spacing: 6) {
            if isSending {
                Text("Sending \(sentCount) of \(sendTarget)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                isConfirmingSendAll = true
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("Send all \(unsent.count)")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(unsent.isEmpty ? Color.secondary : Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(unsent.isEmpty || isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .confirmationDialog(
            "Send \(unsent.count) replies?",
            isPresented: $isConfirmingSendAll,
            titleVisibility: .visible
        ) {
            Button("Send all \(unsent.count)", role: .destructive) {
                Task { await sendAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(recipientSummary)
        }
    }

    /// Names, not a number. "Send 20 replies?" is not informed consent.
    private var recipientSummary: String {
        let names = unsent.map(\.message.sender.name)
        let shown = names.prefix(4).joined(separator: ", ")
        let rest = names.count - min(4, names.count)
        let list = rest > 0 ? "\(shown) and \(rest) more" : shown
        return "Going to \(list). This cannot be undone."
    }

    private var review: some View {
        List {
            ForEach($drafts) { $draft in
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            SenderAvatar(contact: draft.message.sender, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(draft.message.sender.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(draft.message.subject)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        // Editable, because a draft you cannot fix is a draft
                        // you have to throw away.
                        TextField("Reply", text: $draft.body, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(3...10)

                        if let failure = draft.failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if draft.isSent {
                            Label("Sent", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        } else {
                            Button {
                                Task { await send(draft.id) }
                            } label: {
                                Label("Send this reply", systemImage: "paperplane.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(Capsule().fill(Color.accentColor))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) { sendAllBar }
    }

    // MARK: - Work

    private func generateAll() async {
        isWorking = true
        generated = 0
        errorMessage = nil
        defer { isWorking = false }

        let instruction = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var produced: [PendingReply] = []

        // Sequential on purpose. Twenty concurrent model calls is a rate limit
        // and a surprise bill, and the count on the button would be a lie.
        for message in eligible {
            do {
                let draft = try await AIService.draft(
                    replyingTo: message,
                    instruction: instruction.isEmpty
                        ? style.instruction
                        : "\(style.instruction) \(instruction)",
                    tone: user.tonePreference
                )
                produced.append(PendingReply(id: message.id, message: message, body: draft.body))
            } catch {
                produced.append(
                    PendingReply(
                        id: message.id,
                        message: message,
                        body: "",
                        failure: error.localizedDescription
                    )
                )
            }
            generated += 1
        }

        drafts = produced
    }

    /// Sequential, and it stops on nothing -- one failure should not silently
    /// abandon the rest. Whatever fails keeps its error and stays on screen to
    /// be retried individually.
    private func sendAll() async {
        let targets = unsent.map(\.id)
        guard !targets.isEmpty else { return }

        isSending = true
        sentCount = 0
        sendTarget = targets.count
        defer { isSending = false }

        for id in targets {
            await send(id)
            sentCount += 1
        }
    }

    private func send(_ id: Message.ID) async {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let draft = drafts[index]
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            try await store.send(
                subject: draft.message.subject.lowercased().hasPrefix("re:")
                    ? draft.message.subject
                    : "Re: \(draft.message.subject)",
                to: draft.message.sender.address,
                body: draft.body,
                replyingTo: draft.message
            )
            drafts[index].isSent = true
            drafts[index].failure = nil
            store.markRead(draft.message.id)
        } catch {
            drafts[index].failure = error.localizedDescription
        }
    }
}
