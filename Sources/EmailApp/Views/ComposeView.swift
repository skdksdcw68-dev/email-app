import SwiftUI
import UIKit

/// Compose and reply.
///
/// Laid out as plain rows with hairlines rather than a `Form`, to match the
/// reference: the from/to/subject fields read as one continuous header above
/// the body, not as grouped setting cards.
struct ComposeView: View {
    /// When set, the sheet opens as a reply: recipient and subject prefilled,
    /// with the original quoted underneath.
    var replyingTo: Message? = nil
    /// A body written for the user -- an AI draft from dictation, say. It
    /// replaces the quoted-original prefill so they see their reply, not a
    /// wall of quoted text.
    var initialBody: String? = nil

    @Environment(MailStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    @State private var dictation = DictationService()
    /// Latched synchronously on touch-down. onChanged fires continuously and
    /// isRecording only flips once the audio engine is up, so guarding on that
    /// alone lets several starts stack and crash on a duplicate audio tap.
    @State private var isHolding = false
    @State private var isDrafting = false
    @State private var justDrafted = false
    @State private var draftError: String?

    @State private var recipient = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var showsCcBcc = false
    @State private var isConfirmingCancel = false

    private var canSend: Bool {
        recipient.contains("@") && !recipient.hasSuffix("@")
    }

    private var hasContent: Bool {
        !recipient.isEmpty || !subject.isEmpty || !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                fromRow
                divider
                toRow
                divider
                subjectRow
                divider
                bodyEditor
                bottomBar
            }
            .navigationTitle(replyingTo == nil ? "New Message" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: prefill)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasContent { isConfirmingCancel = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.send(subject: subject, to: recipient, body: messageBody)
                        dismiss()
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(canSend ? Color.accentColor : Color.secondary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .confirmationDialog("Keep this draft?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
                Button("Save draft") {
                    store.saveDraft(subject: subject, to: recipient, body: messageBody)
                    dismiss()
                }
                Button("Discard draft", role: .destructive) { dismiss() }
                Button("Continue editing", role: .cancel) {}
            }
        }
    }

    // MARK: - Header rows

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    /// Which account this goes out as. One mailbox today, so the chevron is
    /// inert -- it earns its keep when a second account can be connected.
    private var fromRow: some View {
        HStack(spacing: 10) {
            if let account = store.account {
                SenderAvatar(contact: Contact(name: account.displayName, address: account.email), size: 26)
                Text(account.displayName)
                    .font(.subheadline.weight(.medium))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(account.email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No account connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var toRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("To")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)

                TextField("name@example.com", text: $recipient)
                    .font(.subheadline)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(showsCcBcc ? "Hide" : "Cc/Bcc") {
                    withAnimation(.snappy(duration: 0.2)) { showsCcBcc.toggle() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            if showsCcBcc {
                divider
                HStack(spacing: 10) {
                    Text("Cc")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .leading)

                    TextField("name@example.com", text: $cc)
                        .font(.subheadline)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
    }

    private var subjectRow: some View {
        TextField("Subject", text: $subject)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
    }

    private var bodyEditor: some View {
        TextEditor(text: $messageBody)
            .font(.body)
            .scrollContentBackground(.hidden)
            .foregroundStyle(justDrafted ? Color(uiColor: .systemIndigo) : Color.primary)
            .scaleEffect(justDrafted ? 1.012 : 1)
            .shimmering(justDrafted)
            .animation(.spring(response: 0.5, dampingFraction: 0.62), value: justDrafted)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .overlay(alignment: .topLeading) {
                if messageBody.isEmpty {
                    Text("Write your message")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 14)
                        .padding(.leading, 17)
                        .allowsHitTesting(false)
                }
            }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
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
                    Text(problem).font(.caption).foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 12) {
                Button {
                    // Attachments need a picker and an upload path; neither
                    // exists yet, so this stays visibly unavailable rather
                    // than looking live and doing nothing.
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                }
                .buttonStyle(.plain)
                .disabled(true)
                .frame(width: isExpanded ? 0 : 44)
                .opacity(isExpanded ? 0 : 1)
                .clipped()

                holdToReply
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.74), value: isExpanded)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Full width only while it is doing something. At rest it is a compact
    /// pill, so the paperclip beside it has room to be a real target.
    private var isExpanded: Bool { dictation.isRecording || isDrafting }

    /// Press and hold, speak, release. One view throughout -- swapping it out
    /// mid-press would lose the gesture and the release would never fire.
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
                .lineLimit(1)

            if dictation.isRecording {
                Text("· release to send")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, isExpanded ? 20 : 18)
        .frame(maxWidth: isExpanded ? .infinity : nil)
        .frame(height: dictation.isRecording ? 54 : 46)
        .background(Capsule().fill(dictation.isRecording ? Color.red : Color.accentColor))
        .shadow(color: Color.red.opacity(dictation.isRecording ? 0.35 : 0), radius: 12)
        .contentShape(Capsule())
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

    private func beginHold() {
        guard !isHolding, !isDrafting else { return }
        isHolding = true
        Task { await dictation.start() }
    }

    private func endHold() {
        guard isHolding else { return }
        isHolding = false
        dictation.stop()
        Task { await writeFromDictation() }
    }

    /// The spoken words are an instruction, not the reply text: the model turns
    /// "tell him thursday works" into an actual email, in the tone chosen
    /// during onboarding.
    private func writeFromDictation() async {
        let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original = replyingTo, !spoken.isEmpty else { return }

        isDrafting = true
        draftError = nil
        defer { isDrafting = false }

        do {
            let draft = try await AIService.draft(
                replyingTo: original,
                instruction: spoken,
                tone: user.tonePreference
            )
            messageBody = draft.body
            dictation.reset()

            justDrafted = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                justDrafted = false
            }
        } catch {
            draftError = error.localizedDescription
        }
    }

    // MARK: - Prefill

    /// "Re: Re: x" is nobody's idea of a good subject line.
    /// Recipient and subject only.
    ///
    /// The original is deliberately NOT quoted into the editor. It made every
    /// reply open on a wall of someone else's text that had to be scrolled
    /// past before you could type -- and the thread is one tap away behind the
    /// sheet anyway.
    private func prefill() {
        guard let original = replyingTo, recipient.isEmpty else { return }
        recipient = original.sender.address
        subject = original.subject.lowercased().hasPrefix("re:")
            ? original.subject
            : "Re: \(original.subject)"
        if let initialBody { messageBody = initialBody }
    }
}

#Preview("New") {
    ComposeView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}

#Preview("Reply") {
    let store = MailStore.connected()
    return ComposeView(replyingTo: store.messages(in: .inbox)[0])
        .environment(store)
        .environment(UserStore(defaults: .previews, startAt: .finished))
}
