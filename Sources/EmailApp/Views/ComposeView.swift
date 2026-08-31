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
    @Environment(\.dismiss) private var dismiss

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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
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
        HStack(spacing: 14) {
            Button {
                // Attachments need a picker and an upload path; neither exists
                // yet, so this is deliberately inert rather than misleading.
            } label: {
                Image(systemName: "paperclip")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(true)

            Button {
                store.send(subject: subject, to: recipient, body: messageBody)
                dismiss()
            } label: {
                Text(replyingTo == nil ? "Send message" : "Send reply")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Capsule().fill(canSend ? Color.accentColor : Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Prefill

    /// "Re: Re: x" is nobody's idea of a good subject line.
    private func prefill() {
        guard let original = replyingTo, recipient.isEmpty else { return }
        recipient = original.sender.address
        subject = original.subject.lowercased().hasPrefix("re:")
            ? original.subject
            : "Re: \(original.subject)"
        if let initialBody {
            messageBody = initialBody
        } else {
            messageBody = "\n\n---\nOn \(original.fullDate), \(original.sender.name) wrote:\n\(original.body)"
        }
    }
}

#Preview("New") {
    ComposeView().environment(MailStore.connected())
}

#Preview("Reply") {
    let store = MailStore.connected()
    return ComposeView(replyingTo: store.messages(in: .inbox)[0]).environment(store)
}
