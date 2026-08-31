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
    @State private var richText = NSAttributedString(string: "")
    @State private var isSending = false
    @State private var sendError: String?
    @State private var showsCcBcc = false
    @State private var isConfirmingCancel = false
    @State private var isWriting = false

    /// Derived, never stored: two copies of the body would drift the moment
    /// the AI replaced one of them.
    private var messageBody: String { richText.string }

    private func setBody(_ text: String) {
        richText = NSAttributedString(
            string: text,
            attributes: RichTextEditor.defaultAttributes()
        )
    }

    private var canSend: Bool {
        recipient.contains("@") && !recipient.hasSuffix("@") && !isSending
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
            .dismissesKeyboardOnTap()
            .navigationTitle(replyingTo == nil ? "New Message" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: prefill)
            .sheet(isPresented: $isWriting) {
                AIWriterSheet(
                    replyingTo: replyingTo,
                    existingText: messageBody.trimmingCharacters(in: .whitespacesAndNewlines),
                    tone: user.tonePreference
                ) { written in
                    setBody(written)
                    markJustDrafted()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasContent { isConfirmingCancel = true } else { dismiss() }
                    }
                    // A popover anchored to Cancel, not an action sheet from
                    // the bottom of the screen. presentationCompactAdaptation
                    // is what stops iPhone turning a popover into a sheet.
                    .popover(isPresented: $isConfirmingCancel, arrowEdge: .top) {
                        draftOptions
                            .presentationCompactAdaptation(.popover)
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                        .font(.subheadline.weight(.semibold))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await performSend() }
                    } label: {
                        Label(isSending ? "Sending…" : "Send", systemImage: "paperplane.fill")
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
        }
    }

    // MARK: - Draft popover

    private var draftOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keep this draft?")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            draftOption("Save draft", "tray.and.arrow.down") {
                isConfirmingCancel = false
                Task { await performSaveDraft() }
            }
            Divider()
            draftOption("Discard draft", "trash", isDestructive: true) { dismiss() }
            Divider()
            draftOption("Continue editing", "pencil") { isConfirmingCancel = false }
        }
        .frame(width: 236)
    }

    private func draftOption(
        _ title: String,
        _ symbol: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .frame(width: 18)
                Text(title).font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sending

    /// The sheet stays open when this fails. A compose window that closes on a
    /// failed send loses the message and tells the user it went.
    private func performSend() async {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            try await store.send(
                subject: subject,
                to: recipient,
                cc: showsCcBcc && !cc.isEmpty ? cc : nil,
                body: messageBody,
                html: richText.hasFormatting ? richText.htmlBody() : nil,
                replyingTo: replyingTo
            )
            dismiss()
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func performSaveDraft() async {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            try await store.saveDraft(
                subject: subject,
                to: recipient,
                cc: showsCcBcc && !cc.isEmpty ? cc : nil,
                body: messageBody,
                html: richText.hasFormatting ? richText.htmlBody() : nil,
                replyingTo: replyingTo
            )
            dismiss()
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func markJustDrafted() {
        justDrafted = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            justDrafted = false
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

    /// A UITextView underneath, so selecting text offers the system's Format
    /// menu -- bold, italic, underline -- which SwiftUI's TextEditor cannot do
    /// because it binds to a plain String.
    private var bodyEditor: some View {
        RichTextEditor(
            text: $richText,
            textColor: justDrafted ? .systemIndigo : .label
        )
        // Deliberately not .shimmering here. That modifier masks the view it
        // wraps, and a mask over an editable field clips the caret and the
        // selection highlight out of existence. The colour shift and the
        // spring carry the "this was just written" moment instead.
        .scaleEffect(justDrafted ? 1.012 : 1)
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: justDrafted)
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
            } else if let problem = sendError ?? draftError ?? dictation.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(problem).font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.red)
            }

            // Spacing has to go once the row collapses to a single control.
            // The paperclip shrinks to zero width but the HStack still lays
            // out spacing on both sides of it and of the Spacer, leaving 24pt
            // of dead air to the left of a button that is supposed to be
            // centred -- which is exactly how far off-centre it looked.
            HStack(spacing: isExpanded ? 0 : 12) {
                attachButton
                aiRefineButton
                // Attachment and refine hard left, microphone hard right.
                // Without this the row hugs its contents and the whole cluster
                // floats in the middle of the screen.
                Spacer(minLength: 0)
                holdToReply
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isExpanded)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // The bar spans the screen. Without this it is only as wide as the
        // buttons inside it, and `.bar` paints a floating grey slab around
        // them instead of a toolbar along the bottom edge.
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var attachButton: some View {
        Button {
            // Attachments need a picker and an upload path; neither exists
            // yet, so this stays visibly unavailable rather than looking
            // live and doing nothing.
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
    }

    /// Opens the writer: pick a style, add an instruction, read what it wrote,
    /// and decide. Distinct from dictation, which goes straight into the body.
    private var aiRefineButton: some View {
        Button {
            dismissKeyboard()
            isWriting = true
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(isDrafting ? Color.secondary : Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
        .disabled(isDrafting)
        .frame(width: isExpanded ? 0 : 44)
        .opacity(isExpanded ? 0 : 1)
        .clipped()
        .accessibilityLabel("Write with AI")
    }

    /// Full width only while it is doing something. At rest it is a compact
    /// pill, so the paperclip beside it has room to be a real target.
    ///
    /// Keyed to the finger, not to the audio engine. `isRecording` only turns
    /// true once AVAudioEngine is actually running, which is a good fraction
    /// of a second after the touch lands -- and much longer the first time,
    /// when the permission prompt appears. Animating from it meant every
    /// press felt like the button had missed it.
    private var isExpanded: Bool { isHolding || isDrafting }

    /// Press and hold, speak, release. One view throughout -- swapping it out
    /// mid-press would lose the gesture and the release would never fire.
    ///
    /// Every visual here reads `isHolding`, which is set synchronously on
    /// touch-down, so the button moves in the same frame as the finger.
    private var holdToReply: some View {
        HStack(spacing: 8) {
            if isDrafting {
                ProgressView().tint(.white)
            } else {
                Image(systemName: isHolding ? "waveform" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
            }

            Text(buttonLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if isHolding {
                Text("· release to send")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, isExpanded ? 20 : 18)
        .frame(maxWidth: isExpanded ? .infinity : nil)
        .frame(height: isHolding ? 54 : 46)
        .background(Capsule().fill(isHolding ? Color.red : Color.accentColor))
        .shadow(color: Color.red.opacity(isHolding ? 0.35 : 0), radius: 12)
        .contentShape(Capsule())
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isHolding)
        // A tap on the send button gives a click; this should too, and the
        // haptic is what actually sells the press as instant.
        .sensoryFeedback(.impact(weight: .medium), trigger: isHolding)
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
        return isHolding ? "Recording" : "Hold to Reply"
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

        // Hand straight over to the drafting state. Setting isDrafting inside
        // the task instead costs a runloop hop, and for that hop neither flag
        // is set -- the button snaps back to its compact size and then expands
        // again. The condition has to match writeFromDictation's guard exactly
        // or the spinner would never be cleared.
        let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if replyingTo != nil, !spoken.isEmpty { isDrafting = true }

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
            setBody(draft.body)
            dictation.reset()
            markJustDrafted()
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
        if let initialBody { setBody(initialBody) }
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
