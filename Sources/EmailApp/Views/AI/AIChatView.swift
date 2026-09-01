import SwiftUI
import UIKit

/// The chat, pushed from the AI tab.
///
/// Empty, it is Perplexity's page: the name and nothing else. In use, it is
/// a conversation with an agent that can read the mailbox and write email,
/// but never sends anything without a tap.
///
/// Every message goes down one ladder, on the device, before anything is
/// spent:
///
///   1. Intent. "hi" is a greeting and gets a greeting, never a list of
///      tagged mail. "send it" sends the waiting draft. "reply to Sara
///      saying Thursday works" is an instruction, not a question.
///   2. Action. A draft request is resolved against the mailbox: one clear
///      match is written up as a card; several become a "which one?" with
///      the candidates; none becomes a question about who was meant.
///   3. Local answer. What the mailbox can settle itself -- counts, who is
///      waiting, what needs a reply -- is answered as structure, instantly.
///   4. The model, with the conversation so far and a device-side retrieval
///      digest, streaming prose with sources.
///
/// Sending is the one thing the agent does to the world, and it does it
/// only from the card, only on Send, and reports exactly what happened.
struct AIChatView: View {
    @Environment(MailStore.self) private var mail
    @Environment(UserStore.self) private var user

    @State private var turns: [ChatMessage] = []
    @State private var draft = ""
    @State private var isWorking = false
    @State private var showsOptions = false
    /// Reported by the attached bar, so the conversation leaves room for it.
    /// Starts at the resting capsule height so the first frame is right.
    @State private var barHeight: CGFloat = 54
    @State private var composerReset = 0
    @State private var composerFocus = 0
    /// Emails Maily just put in front of the person, so "the first one" and
    /// "reply to it" mean something on the next turn.
    @State private var offered: [Message] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach($turns) { $turn in
                        ChatTurnView(
                            turn: $turn,
                            onSendDraft: { Task { await sendDraft(in: turn.id) } },
                            onDiscardDraft: { discardDraft(in: turn.id) }
                        )
                        .id(turn.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: turns.count)
            }
            .background {
                if turns.isEmpty {
                    MailyWordmark()
                        // Never moves for the keyboard. See MailyWordmark.
                        .ignoresSafeArea(.keyboard)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: turns.isEmpty)
            // The conversation runs underneath the floating bar and shows
            // through its material; this is only how far the last message
            // clears it.
            .contentMargins(.bottom, barHeight + KeyboardBarController.keyboardGap, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            // A tap anywhere on the conversation puts the keyboard away.
            // Simultaneous, so the links inside answers still fire -- and
            // safe here because this screen has no press-and-hold control
            // for the gesture to fight.
            .simultaneousGesture(TapGesture().onEnded {
                dismissKeyboard()
            })
            .onChange(of: turns.count) { _, _ in
                guard let last = turns.last else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay {
                KeyboardAttachedBar(height: $barHeight) {
                    ChatComposer(
                        text: $draft,
                        showsOptions: $showsOptions,
                        isWorking: isWorking,
                        resetToken: composerReset,
                        focusToken: composerFocus,
                        onSend: send
                    )
                }
                // Full-bleed on purpose: if SwiftUI shrank this for the
                // keyboard, the bar would be back to following SwiftUI's
                // layout instead of UIKit's guide.
                .ignoresSafeArea()
            }
        }
        .keyboardDismissable()
        // No title. The page is the wordmark when empty and the conversation
        // when not; a second "Maily" in the bar would be clutter.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Pushed page, so the tab bar goes.
        .hidesTabBar()
        .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .sheet(isPresented: $showsOptions) {
            ChatOptionsSheet(onPick: handle)
        }
    }

    // MARK: - Chrome

    private var optionsMenu: some View {
        Menu {
            Button(role: .destructive) {
                clearConversation()
            } label: {
                Label("Clear conversation", systemImage: "trash")
            }
            .disabled(turns.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                .contentShape(Circle())
        }
        // Without .plain the toolbar renders its own button background behind
        // this one, and the circle reads as two stacked shapes.
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
    }

    private func clearConversation() {
        withAnimation {
            turns = []
            offered = []
        }
    }

    private func handle(_ option: ChatOption) {
        switch option {
        case .needsReply: ask("What do I need to reply to?")
        case .waiting:    ask("Who am I keeping waiting?")
        case .urgent:     ask("What is urgent right now?")
        case .summary:    ask("Summarise my important emails")
        case .deadlines:  ask("Any deadlines this week?")
        case .clear:      clearConversation()
        case .write:
            // Start the sentence and hand over the cursor.
            draft = "Write an email to "
            composerFocus += 1
        }
    }

    // MARK: - Asking

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        composerReset += 1
        ask(question)
    }

    private func ask(_ question: String) {
        dismissKeyboard()
        turns.append(.user(question))

        let pending = pendingDraftTurn
        switch ChatIntentParser.parse(question, hasPendingDraft: pending != nil) {
        case .greeting(let kind):
            turns.append(.say(greetingReply(kind)))

        case .sendPendingDraft:
            if let pending { Task { await sendDraft(in: pending) } }

        case .discardPendingDraft:
            if let pending {
                discardDraft(in: pending)
                turns.append(.say("Dropped it. Nothing was sent."))
            }

        case .draft(let request):
            Task { await produceDraft(for: request) }

        case .question:
            if let local = mail.localAnswer(for: question) {
                offered = messages(in: local.blocks)
                turns.append(.local(local))
                return
            }
            Task { await askModel(question) }
        }
    }

    /// The newest draft still waiting for a decision, if there is one.
    private var pendingDraftTurn: ChatMessage.ID? {
        turns.last { $0.draft?.status == .ready }?.id
    }

    private func greetingReply(_ kind: ChatIntent.Greeting) -> String {
        switch kind {
        case .hello:
            return "Hey. Ask me about your mail, or tell me who to reply to."
        case .thanks:
            return "Any time."
        case .acknowledgement:
            return "Here if you need me."
        }
    }

    private func messages(in blocks: [AnswerBlock]) -> [Message] {
        blocks.flatMap { block -> [Message] in
            if case .messages(let messages) = block { return messages }
            return []
        }
    }

    // MARK: - The model

    @MainActor
    private func askModel(_ question: String) async {
        // Everything said so far, minus the pending indicator that is about
        // to be added, so "the second one" resolves the way it should.
        let history = turns
            .filter { !$0.isPending && !$0.failed && !$0.text.isEmpty }
            .suffix(10)
            .map { (role: $0.role == .user ? "user" : "assistant", content: $0.text) }

        turns.append(.thinking)
        let pendingID = turns.last?.id

        isWorking = true
        defer { isWorking = false }

        let context = mail.context(for: question)
        do {
            // Streamed, so the answer types itself out instead of landing
            // whole after a long silence.
            try await AIService.askStreaming(question: question, context: context, history: history) { fragment in
                appendDelta(pendingID, fragment)
            }
            finish(pendingID, sources: context)
            offered = context
        } catch {
            replace(pendingID, with: error.localizedDescription, failed: true)
        }
    }

    /// Appends a fragment as it arrives. No animation on each one: animating
    /// every token turns a smooth stream into a stutter.
    private func appendDelta(_ id: ChatMessage.ID?, _ fragment: String) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].isPending = false
        turns[index].text += fragment
    }

    /// Sources land only once the answer is complete, so citations do not pop
    /// in underneath text that is still being written.
    private func finish(_ id: ChatMessage.ID?, sources: [Message]) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            turns[index].sources = sources
            turns[index].isPending = false
        }
    }

    private func replace(_ id: ChatMessage.ID?, with text: String, failed: Bool) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            turns[index].text = text
            turns[index].sources = []
            turns[index].isPending = false
            turns[index].failed = failed
        }
    }

    // MARK: - Writing email

    @MainActor
    private func produceDraft(for request: DraftRequest) async {
        let candidates = mail.draftCandidates(for: request, offered: offered)

        switch candidates.count {
        case 1:
            let target = candidates[0]
            await write(
                to: target.sender,
                replyingTo: target,
                instruction: request.instruction ?? "Reply to what they asked. Keep it short."
            )

        case 0:
            // Nobody in the inbox matched. A known person is still somebody
            // to write to; otherwise the honest move is to ask.
            if let contact = mail.contact(matching: request.hints) {
                await write(
                    to: contact,
                    replyingTo: nil,
                    instruction: request.instruction ?? "Write a short, friendly email."
                )
            } else if request.hints.isEmpty {
                turns.append(.say("Which email? Tell me who sent it, or what it was about."))
            } else {
                turns.append(.say(
                    "I couldn't find anything from \"\(request.hints.joined(separator: " "))\". Who sent it, or what was the subject?"
                ))
            }

        default:
            offered = candidates
            turns.append(ChatMessage(
                role: .assistant,
                text: "Which one did you mean? Say the name or the subject, or \"the first one\".",
                blocks: [.messages(candidates)]
            ))
        }
    }

    @MainActor
    private func write(to contact: Contact, replyingTo original: Message?, instruction: String) async {
        let name = firstName(of: contact)
        turns.append(.working("Writing to \(name)"))
        let pendingID = turns.last?.id

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await AIService.draft(
                replyingTo: original,
                instruction: instruction,
                tone: user.tonePreference
            )

            let subject: String
            if let original {
                subject = original.subject.lowercased().hasPrefix("re:") ? original.subject : "Re: \(original.subject)"
            } else {
                subject = ""
            }

            let chatDraft = ChatDraft(to: contact, subject: subject, body: result.body, replyingTo: original)
            guard let pendingID, let index = turns.firstIndex(where: { $0.id == pendingID }) else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                turns[index].isPending = false
                turns[index].text = original == nil
                    ? "Here's a draft to \(name). Send it, or edit it first."
                    : "Here's a reply to \(name). Send it, or edit it first."
                turns[index].draft = chatDraft
            }
            offered = []
        } catch {
            replace(pendingID, with: "I couldn't write that. \(error.localizedDescription)", failed: true)
        }
    }

    /// Sends the draft on a turn's card, and says what happened -- on the
    /// card and in the conversation.
    @MainActor
    private func sendDraft(in turnID: ChatMessage.ID) async {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let pending = turns[index].draft
        else { return }

        // Ready, or failed and being retried. Never twice while it is going,
        // and never again once it has gone.
        switch pending.status {
        case .ready, .failed: break
        case .sending, .sent: return
        }

        guard !pending.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            turns.append(.say("The draft is empty. Put something in it first."))
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            turns[index].draft?.status = .sending
        }

        do {
            try await mail.send(
                subject: pending.subject,
                to: pending.to.address,
                body: pending.body,
                replyingTo: pending.replyingTo
            )
            if let original = pending.replyingTo { mail.markRead(original.id) }

            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                turns[index].draft?.status = .sent
            }
            turns.append(.say("Sent to \(pending.to.name)."))
        } catch {
            withAnimation(.easeOut(duration: 0.2)) {
                turns[index].draft?.status = .failed(error.localizedDescription)
            }
            var report = ChatMessage.say("It didn't send. \(error.localizedDescription)")
            report.failed = true
            turns.append(report)
        }
    }

    private func discardDraft(in turnID: ChatMessage.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            turns[index].draft = nil
            turns[index].text = "Dropped that draft."
        }
    }

    /// "Sara" rather than "Sara Bekele". Falls back to the whole name, or the
    /// address when there is no name at all.
    private func firstName(of contact: Contact) -> String {
        let parts = contact.name.split(separator: " ")
        guard let first = parts.first, !first.contains("@") else {
            return contact.name.isEmpty ? contact.address : contact.name
        }
        return String(first)
    }
}

#Preview {
    NavigationStack {
        AIChatView()
    }
    .environment(MailStore.connected())
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
