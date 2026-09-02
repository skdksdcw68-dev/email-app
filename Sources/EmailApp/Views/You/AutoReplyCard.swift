import SwiftUI

/// One reply Auto-Reply wrote, in the card the assistant already uses for
/// exactly this in chat.
///
/// Deliberately not a card of its own. An email Maily wrote and is holding is
/// one idea, and it should look and behave the same wherever it turns up:
/// the same envelope, the same Send / Edit / Discard, the same editor with
/// the same one-tap changes and the same "ask for changes" field. Somebody
/// who has edited one in chat already knows how to edit this.
///
/// What Auto-Reply adds underneath is its own: which approved facts the reply
/// leaned on, and -- more importantly -- what it deliberately did not answer.
/// That second list is why the whole thing can be trusted, so it sits with
/// the reply rather than a screen away.
struct AutoReplyCard: View {
    let decision: AutoReplyDecision

    @Environment(MailStore.self) private var mail
    @Environment(AutoReplyQueue.self) private var queue
    @Environment(UserStore.self) private var user

    @State private var draft: ChatDraft
    @State private var isEditing = false
    @State private var failure: String?

    init(decision: AutoReplyDecision) {
        self.decision = decision
        _draft = State(initialValue: ChatDraft(
            to: Contact(name: decision.from, address: ""),
            subject: decision.subject,
            body: decision.reply ?? ""
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmailDraftCard(
                draft: $draft,
                onSend: { Task { await send() } },
                onEdit: { isEditing = true },
                onDiscard: { queue.discard(decision.id) }
            )

            reasoning

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isEditing) {
            DraftEditorView(
                draft: $draft,
                tone: user.tonePreference,
                onSend: { Task { await send() } }
            )
        }
        // The reply and its recipient are filled in from the message it
        // answers, which the store holds. Done here rather than in the
        // initialiser because a View's init cannot reach the environment.
        .task { fillInRecipient() }
    }

    /// Why this reply says what it says, and what it left alone.
    @ViewBuilder
    private var reasoning: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !decision.reason.isEmpty {
                Text(decision.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(decision.evidence, id: \.self) { fact in
                label("checkmark.circle.fill", fact, .green)
            }

            if !decision.withheld.isEmpty {
                ForEach(decision.withheld, id: \.self) { item in
                    label("hand.raised.fill", item, .orange)
                }
                Text("Maily left these for you. Add them yourself before sending, if you want to.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private func label(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The address, and the message being answered so a revision has the
    /// original in front of it.
    private func fillInRecipient() {
        guard draft.to.address.isEmpty,
              let original = mail.messages.first(where: { $0.remoteID == decision.messageID })
        else { return }
        draft.to = original.sender
        draft.replyingTo = original
        if draft.subject.isEmpty { draft.subject = original.subject }
    }

    private func send() async {
        guard draft.status != .sending, draft.status != .sent else { return }
        failure = nil
        draft.status = .sending

        // Whatever is in the card is what goes, edits and AI revisions
        // included. Sending the model's first attempt after somebody changed
        // it would be the worst bug this feature could have.
        var edited = decision
        edited.reply = draft.body

        do {
            try await mail.sendAutoReply(edited, queue: queue)
            draft.status = .sent
        } catch {
            draft.status = .failed(error.localizedDescription)
            failure = error.localizedDescription
        }
    }
}

/// How many replies are waiting, in red.
///
/// Red because it is the one number in this feature that is a to-do rather
/// than a statistic: somebody wrote in, Maily answered, and the reply is
/// sitting there unsent. Capped at 9+ so the bubble stays a dot rather than
/// a smear, which is the same reason the tab badge caps.
struct WaitingBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 9 ? "9+" : "\(count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, count > 9 ? 6 : 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
                .accessibilityLabel(count == 1 ? "1 reply waiting" : "\(count) replies waiting")
        }
    }
}
