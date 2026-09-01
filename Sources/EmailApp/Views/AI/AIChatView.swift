import SwiftUI
import UIKit

/// The chat, pushed from the AI tab.
///
/// Empty, it is Perplexity's page: the name and nothing else. In use, it is
/// a conversation with an agent that can read the mailbox and write email,
/// but never sends anything without a tap. Conversations are kept: this
/// screen opens fresh, or on a saved one by id, and saves itself as it goes.
///
/// Every message goes down one ladder, on the device, before anything is
/// spent:
///
///   1. Intent. "hi" is a greeting and gets a greeting, never a list of
///      tagged mail. "send it" sends the waiting draft. "reply to Sara
///      saying Thursday works" is an instruction, not a question.
///   2. Action. A draft request is resolved against the mailbox: one clear
///      match is written up as a card; several become a "which one?" with
///      the candidates, and the next message picks from them; none becomes
///      a question about who was meant.
///   3. Local answer. What the mailbox can settle itself -- counts, who is
///      waiting, what needs a reply -- is answered as structure, instantly.
///   4. The model, with the conversation so far and a device-side retrieval
///      digest, streaming prose with sources. If *it* writes an email, the
///      email comes back in a block that becomes a card, never as prose.
///
/// Anything the model is doing can be stopped from the composer. Sending is
/// the one thing the agent does to the world, and it does it only from the
/// card, only on Send, and reports exactly what happened.
struct AIChatView: View {
    /// A saved conversation to pick up, or nil for a new one.
    var conversationID: UUID? = nil

    @Environment(MailStore.self) private var mail
    @Environment(UserStore.self) private var user
    @Environment(ChatHistory.self) private var history

    @State private var turns: [ChatMessage] = []
    @State private var draft = ""
    @State private var isWorking = false
    @State private var showsOptions = false
    @State private var showsHistory = false
    /// Reported by the attached bar: its own height, so the conversation
    /// leaves room for it and the empty page centres above it.
    @State private var barHeight: CGFloat = 54
    @State private var composerReset = 0
    @State private var composerFocus = 0
    /// Emails Maily just put in front of the person, so "the first one" and
    /// "reply to it" mean something on the next turn.
    @State private var offered: [Message] = []
    /// A draft request waiting on the answer to "which one?".
    @State private var pendingChoice: DraftRequest?
    /// The model call in flight, so the stop button has something to stop.
    @State private var work: Task<Void, Never>?
    @State private var editing: EditingDraft?
    /// The saved conversation this screen is writing to, once it has one.
    @State private var currentID: UUID?

    private struct EditingDraft: Identifiable {
        let id: ChatMessage.ID
    }

    /// What the composer is built from. The UIKit host rebuilds its content
    /// only when this changes, not on every streamed token.
    private struct ComposerInputs: Equatable {
        var text: String
        var showsOptions: Bool
        var isWorking: Bool
        var reset: Int
        var focus: Int
    }

    /// The name is the empty page. It goes the moment there is anything in
    /// the field -- a space counts -- not when the first message lands.
    private var showsWordmark: Bool {
        turns.isEmpty && draft.isEmpty
    }

    private var composerInputs: ComposerInputs {
        ComposerInputs(
            text: draft, showsOptions: showsOptions, isWorking: isWorking,
            reset: composerReset, focus: composerFocus
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach($turns) { $turn in
                        ChatTurnView(
                            turn: $turn,
                            onSendDraft: { Task { await sendDraft(in: turn.id) } },
                            onEditDraft: {
                                dismissKeyboard()
                                editing = EditingDraft(id: turn.id)
                            },
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
                if showsWordmark {
                    // Centred in what is left above the bar and the keyboard,
                    // which is where Perplexity puts theirs. SwiftUI already
                    // moves this layer up for the keyboard on its own; only
                    // the bar's height is added here. Adding the keyboard's
                    // height as well pushed the name to the top of the screen.
                    MailyWordmark()
                        .padding(.bottom, barHeight + KeyboardBarController.keyboardGap)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: showsWordmark)
            // Room for the bar. The conversation runs underneath it and shows
            // through its material; this is only how far the last message
            // clears it -- and it grows with the bar, so nothing is left
            // hidden behind a taller capsule.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: barHeight + KeyboardBarController.keyboardGap)
                    .allowsHitTesting(false)
            }
            .scrollDismissesKeyboard(.interactively)
            // A tap anywhere on the conversation puts the keyboard away.
            // Simultaneous, so the links inside answers still fire -- and
            // safe here because this screen has no press-and-hold control
            // for the gesture to fight.
            .simultaneousGesture(TapGesture().onEnded {
                dismissKeyboard()
            })
            .onChange(of: turns.count) { _, _ in
                scrollToEnd(proxy, animation: .easeOut(duration: 0.3))
            }
            // The bar grew a line: keep the last message above it, the way
            // the platform's assistants keep the bottom pinned.
            .onChange(of: barHeight) { _, _ in
                scrollToEnd(proxy, animation: .easeOut(duration: 0.18))
            }
            .overlay {
                KeyboardAttachedBar(height: $barHeight, inputs: composerInputs) {
                    ChatComposer(
                        text: $draft,
                        showsOptions: $showsOptions,
                        isWorking: isWorking,
                        resetToken: composerReset,
                        focusToken: composerFocus,
                        onSend: send,
                        onStop: stop
                    )
                }
                // Full-bleed on purpose: if SwiftUI shrank this for the
                // keyboard, the bar would be back to following SwiftUI's
                // layout instead of UIKit's positioning.
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
        // Deliberately no navigationDestination here. The AI tab's stack
        // resolves Message.ID; declaring it again inside a pushed view made
        // SwiftUI rebuild this screen when a card was tapped.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        startNewChat()
                    } label: {
                        Label("New chat", systemImage: "plus.bubble")
                    }
                    .disabled(turns.isEmpty)

                    Button {
                        showsHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }

                    Divider()

                    Button(role: .destructive) {
                        deleteCurrentChat()
                    } label: {
                        Label("Delete this chat", systemImage: "trash")
                    }
                    .disabled(turns.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More options")
            }
        }
        .sheet(isPresented: $showsOptions) {
            ChatOptionsSheet(onPick: handle)
        }
        .sheet(isPresented: $showsHistory) {
            NavigationStack {
                ChatHistoryView { conversation in
                    open(conversation)
                    showsHistory = false
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { showsHistory = false }
                    }
                }
            }
        }
        .fullScreenCover(item: $editing) { item in
            if let binding = draftBinding(for: item.id) {
                DraftEditorView(draft: binding, tone: user.tonePreference) {
                    Task { await sendDraft(in: item.id) }
                }
            }
        }
        .task { restoreConversationIfNeeded() }
        // Saved whenever the conversation settles: local answers, greetings,
        // sends, and each model answer once it has finished streaming. Not
        // per token -- that is `isWorking` below.
        .onChange(of: turns) { _, _ in
            if !isWorking { persistConversation() }
        }
        .onChange(of: isWorking) { _, working in
            if !working { persistConversation() }
        }
    }

    // MARK: - Chrome

    private func scrollToEnd(_ proxy: ScrollViewProxy, animation: Animation) {
        guard let last = turns.last else { return }
        withAnimation(animation) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func handle(_ option: ChatOption) {
        switch option {
        case .needsReply: ask("What do I need to reply to?")
        case .waiting:    ask("Who am I keeping waiting?")
        case .urgent:     ask("What is urgent right now?")
        case .summary:    ask("Summarise my important emails")
        case .deadlines:  ask("Any deadlines this week?")
        case .newChat:    startNewChat()
        case .write:
            // Start the sentence and hand over the cursor.
            draft = "Write an email to "
            composerFocus += 1
        }
    }

    /// A live binding into the draft on one turn, for the editor.
    private func draftBinding(for turnID: ChatMessage.ID) -> Binding<ChatDraft>? {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              turns[index].draft != nil
        else { return nil }
        return Binding(
            get: { turns[index].draft ?? ChatDraft(to: Contact(name: "", address: ""), subject: "", body: "") },
            set: { turns[index].draft = $0 }
        )
    }

    // MARK: - History

    /// Opened on a saved conversation: bring it back, once.
    private func restoreConversationIfNeeded() {
        guard turns.isEmpty, currentID == nil,
              let conversationID,
              let conversation = history.conversation(conversationID)
        else { return }
        open(conversation)
    }

    private func open(_ conversation: Conversation) {
        work?.cancel()
        turns = conversation.turns.map { turn in
            var turn = turn
            turn.isPending = false
            // A send that was mid-flight when the app closed never finished.
            if turn.draft?.status == .sending { turn.draft?.status = .ready }
            return turn
        }
        currentID = conversation.id
        offered = []
        pendingChoice = nil
    }

    /// Writes what is on screen to history, minus anything still pending.
    private func persistConversation() {
        let settled = turns.filter { !$0.isPending }
        guard !settled.isEmpty else { return }

        let now = Date.now
        if let currentID, var existing = history.conversation(currentID) {
            existing.turns = settled
            existing.updatedAt = now
            history.save(existing)
        } else {
            let conversation = Conversation(
                title: Conversation.title(for: settled),
                createdAt: now,
                updatedAt: now,
                turns: settled
            )
            currentID = conversation.id
            history.save(conversation)
        }
    }

    /// Starts fresh. The conversation on screen is already in History.
    private func startNewChat() {
        work?.cancel()
        withAnimation {
            turns = []
            offered = []
            pendingChoice = nil
        }
        currentID = nil
    }

    private func deleteCurrentChat() {
        if let currentID { history.delete(currentID) }
        startNewChat()
    }

    // MARK: - Asking

    /// The keyboard stays up after a send. Putting it away made every
    /// follow-up start with a tap on the field.
    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        composerReset += 1
        ask(question)
    }

    /// Ends whatever the model is doing. The partial answer stays.
    private func stop() {
        work?.cancel()
    }

    private func ask(_ question: String) {
        turns.append(.user(question))

        let pending = pendingDraftTurn
        let intent = ChatIntentParser.parse(question, hasPendingDraft: pending != nil)

        // An answer to "which one?" -- "Drobe", "the second", "the one from
        // Sara" -- is picked from what was offered, not read as a question.
        if let choice = pendingChoice, !offered.isEmpty, case .question = intent {
            let pick = ChatIntentParser.selection(question)
            if pick.hints.isEmpty && pick.ordinal == nil {
                // Not a choice at all; they moved on.
                pendingChoice = nil
            } else {
                let request = DraftRequest(
                    instruction: choice.instruction, hints: pick.hints,
                    ordinal: pick.ordinal, isNewEmail: choice.isNewEmail
                )
                let narrowed = mail.draftCandidates(for: request, offered: offered, within: offered)
                if narrowed.count == 1 {
                    pendingChoice = nil
                    let target = narrowed[0]
                    work = Task {
                        await write(
                            to: target.sender, replyingTo: target,
                            instruction: choice.instruction ?? "Reply to what they asked. Keep it short."
                        )
                    }
                    return
                }
                if narrowed.count > 1 {
                    offered = narrowed
                    turns.append(ChatMessage(
                        role: .assistant,
                        text: "Still a few. Which one?",
                        blocks: [.messages(narrowed)]
                    ))
                    return
                }
                pendingChoice = nil
            }
        }

        switch intent {
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
            work = Task { await produceDraft(for: request) }

        case .question:
            if let local = mail.localAnswer(for: question) {
                offered = messages(in: local.blocks)
                turns.append(.local(local))
                return
            }
            work = Task { await askModel(question) }
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
            if isCancellation(error) {
                stopped(pendingID, sources: context)
            } else {
                replace(pendingID, with: error.localizedDescription, failed: true)
            }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Appends a fragment as it arrives. No animation on each one: animating
    /// every token turns a smooth stream into a stutter.
    private func appendDelta(_ id: ChatMessage.ID?, _ fragment: String) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].isPending = false
        turns[index].text += fragment
    }

    /// The answer is complete. Sources land now, so citations do not pop in
    /// underneath text that is still being written -- and if the model wrote
    /// an email, it is lifted out of the prose into a card here.
    private func finish(_ id: ChatMessage.ID?, sources: [Message]) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }

        var text = turns[index].text
        var emailDraft: ChatDraft?
        if let (prose, block) = EmailBlock.extract(from: text) {
            emailDraft = makeDraft(from: block, sources: sources)
            text = prose.isEmpty ? "Here's the email. Send it, or edit it first." : prose
        }

        withAnimation(.easeOut(duration: 0.25)) {
            turns[index].text = text
            turns[index].draft = emailDraft
            // A draft is its own evidence; the list of emails behind it is
            // noise next to a card that names the recipient.
            turns[index].sources = emailDraft == nil ? sources : []
            turns[index].isPending = false
        }
    }

    /// The person stopped it. Whatever had arrived stays, minus any email
    /// block that never finished -- half an envelope is not a draft.
    private func stopped(_ id: ChatMessage.ID?, sources: [Message]) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }

        var text = turns[index].text
        if let open = text.range(of: EmailBlock.opening),
           text[open.upperBound...].range(of: EmailBlock.closing) == nil {
            text = String(text[..<open.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            replace(id, with: "Stopped.", failed: false)
        } else {
            turns[index].text = text
            finish(id, sources: sources)
        }
    }

    /// A block the model wrote, threaded onto the email it answers when the
    /// address matches one we showed it.
    private func makeDraft(from block: EmailBlock, sources: [Message]) -> ChatDraft {
        let address = block.toAddress
        let original = sources.first { !address.isEmpty && $0.sender.address.lowercased() == address.lowercased() }
        let name = block.toName.isEmpty ? (original?.sender.name ?? "") : block.toName
        return ChatDraft(
            to: Contact(name: name, address: address),
            subject: block.subject,
            body: block.body,
            replyingTo: original
        )
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
            pendingChoice = nil
            let target = candidates[0]
            await write(
                to: target.sender,
                replyingTo: target,
                instruction: request.instruction ?? "Reply to what they asked. Keep it short."
            )

        case 0:
            pendingChoice = nil
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
            pendingChoice = request
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
            pendingChoice = nil
        } catch {
            if isCancellation(error) {
                replace(pendingID, with: "Stopped.", failed: false)
            } else {
                replace(pendingID, with: "I couldn't write that. \(error.localizedDescription)", failed: true)
            }
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

        guard !pending.to.address.trimmingCharacters(in: .whitespaces).isEmpty else {
            turns.append(.say("It needs an address first. Tap edit on the card and add one."))
            return
        }
        guard !pending.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            turns.append(.say("The draft is empty. Put something in it first."))
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            turns[index].draft?.status = .sending
        }

        let cc = pending.cc.trimmingCharacters(in: .whitespaces)
        do {
            try await mail.send(
                subject: pending.subject,
                to: pending.to.address,
                cc: cc.isEmpty ? nil : cc,
                body: pending.body,
                replyingTo: pending.replyingTo
            )
            if let original = pending.replyingTo { mail.markRead(original.id) }

            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                turns[index].draft?.status = .sent
            }
            let recipient = pending.to.name.isEmpty ? pending.to.address : pending.to.name
            turns.append(.say("Sent to \(recipient)."))
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
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
    }
    .environment(MailStore.connected())
    .environment(UserStore(defaults: .previews, startAt: .finished))
    .environment(ChatHistory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-chats.json")))
}
