import SwiftUI
import UIKit

/// The chat, pushed from the AI tab.
///
/// Empty, it is Perplexity's page: the name and nothing else. In use, it is
/// a conversation with an agent that can read the mailbox and write email,
/// but never sends anything without a tap. Conversations are kept: this
/// screen opens fresh, or on a saved one by id, and saves itself as it goes.
///
/// The model answers everything. There used to be a ladder of local rules
/// above it -- canned greetings, a keyword table that turned "what needs a
/// reply" into a template and "what did Sara say about the meeting" into the
/// wrong list -- and it made the app feel stupid in exactly the moments
/// somebody was asking for something specific. It is gone. What survives on
/// the device is the two things that are not answers:
///
///   1. Actions, where guessing wrong costs something real: sending a draft
///      that is waiting, discarding it, marking mail read.
///   2. Retrieval, so a question arrives at the model with the dozen emails
///      that bear on it and the shape of the inbox they came from. That is
///      data, not a decision.
///
/// Structure survives too, but the model asks for it now: it fences tiles
/// and charts the way it already fenced emails, and the app draws what it is
/// handed rather than guessing which questions deserve a picture.
///
/// Anything the model is doing can be stopped from the composer. Sending is
/// the one thing the agent does to the world, and it does it only from the
/// card, only on Send, and reports exactly what happened.
struct AIChatView: View {
    /// A saved conversation to pick up, or nil for a new one.
    var conversationID: UUID? = nil
    /// A conversation that has gone quiet, opened straight into a chase.
    /// The chat starts with the follow-up already being written, because
    /// coming here from "Nudge" and being shown an empty box would be a
    /// worse version of what the button promised.
    var nudging: Message.ID? = nil

    @Environment(MailStore.self) private var mail
    @Environment(UserStore.self) private var user
    @Environment(ChatHistory.self) private var history
    @Environment(AIMemory.self) private var memory

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
    /// What this conversation is about: what has been searched for, who it
    /// concerns, what is still unanswered. See `ChatState` -- without it the
    /// chat carries a transcript rather than a memory.
    @State private var state = ChatState.fresh
    /// The model call in flight, so the stop button has something to stop.
    @State private var work: Task<Void, Never>?

    /// Tokens that have arrived but not yet been drawn.
    ///
    /// A class on purpose, and it is the whole point: `@State` watches the
    /// *reference*, so appending to a property inside it invalidates nothing.
    /// A `@State String` would redraw the conversation on every token, which
    /// is exactly the thing being fixed.
    @State private var stream = StreamBuffer()

    /// How long tokens are allowed to pile up before being drawn, in
    /// milliseconds. Twelve updates a second: fast enough to read as typing,
    /// slow enough that the view is not rebuilt eighty times a second.
    private static let streamFlushInterval = 80
    @State private var editing: EditingDraft?
    /// The saved conversation this screen is writing to, once it has one.
    @State private var currentID: UUID?

    private struct EditingDraft: Identifiable {
        let id: ChatMessage.ID
    }

    /// Where streamed tokens wait between draws.
    ///
    /// Main-actor isolated rather than locked: every writer is a SwiftUI
    /// callback and `AIService.askStreaming` already declares its `onDelta` as
    /// `@MainActor`, so there is one thread and a lock would buy nothing but
    /// a chance to hold it during I/O.
    @MainActor
    private final class StreamBuffer {
        var pending = ""
        var isFlushScheduled = false
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
                            onDiscardDraft: { discardDraft(in: turn.id) },
                            onUndo: { undo(in: turn.id) }
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
                // Air between the last answer and the capsule. At 8 the two
                // read as one block; the answer wants to end before the input
                // begins.
                .padding(.bottom, 24)
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
                        FlowCloseButton { showsHistory = false }
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
        .task {
            restoreConversationIfNeeded()
            startNudgeIfNeeded()
        }
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
        // A reopened conversation starts without one. What was tried is
        // not saved with the turns, and inventing it from the text would
        // be a guess presented as a record.
        state = .fresh
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
            state = .fresh
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
        case .sendPendingDraft:
            if let pending { Task { await sendDraft(in: pending) } }

        case .discardPendingDraft:
            if let pending {
                discardDraft(in: pending)
                turns.append(.say("Dropped it. Nothing was sent."))
            }

        case .draft(let request):
            work = Task { await produceDraft(for: request) }

        case .markRead(let request):
            markRead(request)

        case .question:
            work = Task { await askModel(question) }
        }
    }

    /// The newest draft still waiting for a decision, if there is one.
    private var pendingDraftTurn: ChatMessage.ID? {
        turns.last { $0.draft?.status == .ready }?.id
    }


    // MARK: - Marking read

    /// The one thing Maily can change about a message, so it is worth doing
    /// well: say exactly how many, say where it applies, and offer it back.
    private func markRead(_ request: MarkReadRequest) {
        let targets: [Message]
        let pile: String

        if request.isEverything {
            targets = mail.messages(in: .inbox).filter { !$0.isRead }
            pile = "everything"
        } else if let custom = request.custom {
            // One of their own: "mark the support requests read".
            targets = mail.messages(in: .inbox, custom: custom.id).filter { !$0.isRead }
            pile = custom.name
        } else if let tag = request.tag {
            targets = mail.messages(in: .inbox, tag: tag).filter { !$0.isRead }
            pile = CategoryStore.shared.category(for: tag).name
        } else if !offered.isEmpty {
            // Nothing named: they mean whatever was just on screen.
            targets = offered.filter { !$0.isRead }
            pile = "those"
        } else {
            turns.append(.say("Which ones? Name a tag, say \"all\", or ask me to list something first."))
            return
        }

        guard !targets.isEmpty else {
            turns.append(.say(
                request.isEverything
                    ? "Everything in your inbox is already read."
                    : "Nothing unread in \(pile)."
            ))
            return
        }

        let changed = mail.markRead(targets.map(\.id))
        Analytics.record(.markedRead, [
            "count": .int(changed.count),
            "scope": .string(
                request.isEverything ? "all"
                    : request.custom != nil ? "custom"
                    : (request.tag?.rawValue ?? "listed")
            ),
        ])
        let title = changed.count == 1
            ? "Marked 1 email as read"
            : "Marked \(changed.count) emails as read"

        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            turns.append(.did(ChatReceipt(
                symbol: "envelope.open",
                title: title,
                // Said once, on the card, rather than in every answer after.
                detail: "Inside Maily only. Gmail elsewhere still shows them unread.",
                undo: changed
            )))
        }
    }

    // MARK: - Chasing

    /// Opened from a follow-up. Goes straight to the writer with the exact
    /// message in hand, rather than through the intent parser, so there is
    /// no chance of chasing the wrong person about the wrong thread.
    private func startNudgeIfNeeded() {
        guard let nudging, turns.isEmpty, let target = mail.message(nudging) else { return }

        let days = Calendar.current.dateComponents([.day], from: target.date, to: .now).day ?? 0
        let name = firstName(of: target.sender)
        turns.append(.user("Follow up with \(name) about \"\(target.subject)\""))

        work = Task {
            await write(
                to: target.sender,
                replyingTo: target,
                instruction: """
                Write a short, friendly follow-up. It has been \(days) days with no reply. \
                Do not repeat the original message back at them, do not apologise for \
                chasing, and do not invent anything that was not already agreed. One or \
                two sentences, ending with a clear ask.
                """
            )
        }
    }

    private func undo(in turnID: ChatMessage.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let receipt = turns[index].receipt, !receipt.isUndone
        else { return }

        mail.markRead(receipt.undo, false)
        Analytics.record(.markedReadUndone, ["count": .int(receipt.undo.count)])
        withAnimation(.snappy(duration: 0.25)) {
            turns[index].receipt?.isUndone = true
        }
    }

    // MARK: - The model

    @MainActor
    private func askModel(_ question: String) async {
        // Everything said so far, minus the pending indicator that is about
        // to be added, so "the second one" resolves the way it should.
        let history = turns
            .filter { !$0.isPending && !$0.failed && !$0.text.isEmpty }
            .suffix(6)
            .map { (role: $0.role == .user ? "user" : "assistant", content: $0.text) }

        // The trail from the first moment, on every question. "Thinking" with
        // three dots was what plain questions showed while searches got the
        // trail, so the same app looked like two apps.
        turns.append(.working(.understanding()))
        let pendingID = turns.last?.id
        let started = Date.now

        isWorking = true
        defer { isWorking = false }

        // Empty when the question is not about mail at all -- "what can you
        // do", "how does this work". A short follow-up borrows the subject of
        // whatever Maily said last, so "yes" still arrives with the mail it
        // is agreeing to.
        var context = mail.context(for: question, following: history.last(where: { $0.role == "assistant" })?.content)

        // What the app has already read out of their mail -- who is waiting
        // on whom, and for what -- and the messages it read it from, so a
        // fact the model leans on can be shown as a card rather than only
        // described. Withheld with everything else when the question is not
        // about mail. The messages stay through every trim below: a fact
        // pointing at a message the model cannot see is a fact it cannot
        // show.
        let facts = context.isEmpty ? [] : mail.facts.forPrompt()
        // Who the question is plainly about, and where things stand with
        // them. "What is happening with Sara" used to mean handing over a
        // dozen of Sara's emails and hoping; the app already knows the
        // answer and can just say it.
        //
        // When the question names nobody, the conversation's own people
        // stand in. "And what did she say about the invoice?" used to lose
        // Sara entirely, because who a question is about was worked out from
        // that question's own words and nothing else.
        var standings = context.isEmpty ? [] : mail.peopleMentioned(in: question)
        if standings.isEmpty && !context.isEmpty && !state.people.isEmpty {
            standings = state.people.flatMap { mail.peopleMentioned(in: $0, limit: 1) }
        }
        state.asking(question, about: standings.map(\.person.contact.name))
        var pinned = Set<Message.ID>()
        if !facts.isEmpty {
            let wanted = Set(facts.map(\.messageID))
            var known = Set(context.map(\.id))
            let sources = mail.messages
                .filter { message in
                    guard let remoteID = message.remoteID, wanted.contains(remoteID) else { return false }
                    return known.insert(message.id).inserted
                }
                .prefix(Self.factSources)
            pinned = Set(sources.map(\.id))
            context += sources
            context.sort { $0.date > $1.date }
        }

        // Filled as the investigation goes, and only by it.
        //
        // The app used to decide when to search from whether any word in the
        // question turned up in a subject. "The last email I got was what"
        // lost "email" and "what" as stop words, was left with "last", found
        // no subject containing it, and searched the whole account for "Hi".
        // No rule about words knows what a question means. The model does,
        // and it says SEARCH: when it needs to.
        var searchedFor: String?
        var found: [Message] = []
        // Messages the model asked to read properly, carried at length on
        // every hop after it asked.
        var opened: Set<Message.ID> = []

        do {
            var hopsLeft = Self.searchHops

            // One pass per hop. The model either answers, or asks to look
            // and gets asked again with what came back.
            //
            // One hop was not enough. A first guess at the words that would
            // be in an email is often wrong, and the old loop had exactly one
            // guess before it had to answer -- so "when did I register" came
            // back as "not in your mail" the moment the first query missed.
            // Three hops is an investigation: guess, see what came back,
            // guess better.
            while true {
                try await AIService.askStreaming(
                    question: question,
                    context: context,
                    history: history,
                    // Fifty tokens, and it lets the model answer about piles
                    // it was not shown. Withheld only when nothing about this
                    // is about mail, which is what keeps an aside cheap.
                    inbox: context.isEmpty ? nil : mail.tagSummary,
                    signedInAs: user.account?.displayName,
                    occupation: user.account?.occupation,
                    tone: user.tonePreference,
                    memories: memory.prompt,
                    // Numbered against this hop's context, which a search may
                    // have reordered since the last one.
                    facts: FactStore.describe(facts, numbered: context),
                    inFull: opened,
                    // The person's names for their categories, and the
                    // ones they made, so the digest speaks their language.
                    names: CategoryStore.shared.names,
                    people: standings.map { $0.described() }.joined(separator: "\n\n"),
                    hopsLeft: hopsLeft,
                    hasSearched: searchedFor != nil,
                    // What this conversation has already tried, so "try
                    // again" is a different attempt rather than the same one.
                    state: state.briefing()
                ) { fragment in
                    appendDelta(pendingID, fragment)
                }

                guard let request = SearchRequest.extract(from: currentText(of: pendingID)),
                      hopsLeft > 0 else { break }

                // What streamed in was the request, not an answer. Showing
                // "SEARCH: upwork welcome" to the reader is showing them the
                // plumbing.
                clearText(of: pendingID)

                // It can see the right message and needs to actually read it.
                // Nothing is fetched: the app already holds these, and the
                // only thing that changes is how much of them goes over.
                guard request.kind.needsGmail else {
                    let wanted = request.numbers(within: context.count)
                        .map { context[$0 - 1] }
                    guard !wanted.isEmpty else { break }

                    opened.formUnion(wanted.map(\.id))
                    record(pendingID, [.readingInFull(wanted)])
                    hopsLeft -= 1
                    continue
                }

                let report = await mail.investigate(request)
                record(pendingID, report.steps)

                // Every query this conversation has put to Gmail, and whether
                // it was worth putting. The empty ones are the point: the
                // next hop is told not to try those words again.
                for query in request.queries {
                    state.searched(query, found: report.found.count)
                }

                searchedFor = report.answered ?? request.queries.first
                var seen = Set<Message.ID>(found.map(\.id))
                found += report.found.filter { seen.insert($0.id).inserted }

                var known = Set<Message.ID>(context.map(\.id))
                context += report.found.filter { known.insert($0.id).inserted }
                // Newest first, still. The prompt promises the model that the
                // first message is the most recent, and a search result
                // appended at the end would quietly make that false.
                context.sort { $0.date > $1.date }
                // Within what the server will read. What was found stays,
                // whatever its date; it is the oldest recent mail that goes,
                // because a 2019 welcome email sorted to the bottom and then
                // cut off the end would be a search that found nothing.
                if context.count > Self.contextCeiling {
                    let keep = Set(found.map(\.id))
                    var spare = context.count - Self.contextCeiling
                    context = context.reversed().filter { message in
                        guard spare > 0, !keep.contains(message.id) else { return true }
                        spare -= 1
                        return false
                    }.reversed()
                }

                // What the model is doing next is the step left open: reading
                // what came back, or, when nothing did, deciding what else the
                // email might have said. Counted from what was found.
                begin(pendingID, found.isEmpty ? .rethinking() : .reading(found))

                hopsLeft -= 1
            }

            // An aside is not what the conversation is about. "What can you
            // do" should not become the thing every later question is
            // answered in terms of.
            if context.isEmpty {
                state.setAside()
            } else {
                state.answered(found: found.count, searched: searchedFor != nil)
            }

            finish(pendingID, context: context, searchNote: searchedFor, found: found)
            // What is on screen is what "reply to it" means next turn: the
            // emails the model showed if it showed any, else everything it
            // was reading from.
            offered = shown(in: pendingID) ?? context

            Analytics.record(.chatAsked, [
                "length": .int(question.count),
                "words": .int(question.split(separator: " ").count),
                "used_mail": .bool(!context.isEmpty),
                "emails": .int(context.count),
                "seconds": .int(Int(Date.now.timeIntervalSince(started))),
                "wrote_email": .bool(turns.last?.draft != nil),
                "drew_blocks": .int(turns.last?.blocks.count ?? 0),
            ])
        } catch {
            if isCancellation(error) {
                stopped(pendingID, sources: context)
                Analytics.record(.chatStopped, ["seconds": .int(Int(Date.now.timeIntervalSince(started)))])
            } else {
                replace(pendingID, with: error.localizedDescription, failed: true)
                Analytics.record(.chatFailed, ["used_mail": .bool(!context.isEmpty)])
            }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// How many times the model may ask to look before it has to answer.
    /// Three: enough to guess, see what came back, and guess better.
    static let searchHops = 3

    /// The most messages a question carries to the model. The server reads
    /// this many and no more, so the app decides which ones rather than
    /// letting the cut fall wherever the list happened to end.
    static let contextCeiling = 25

    /// The most messages carried along because a fact points at them. A
    /// dozen: the facts the prompt gets are capped at thirty, and most of
    /// them share a handful of threads.
    static let factSources = 12

    /// The emails the model put on screen in this turn, if any.
    private func shown(in id: ChatMessage.ID?) -> [Message]? {
        guard let id, let turn = turns.first(where: { $0.id == id }) else { return nil }
        let messages = turn.blocks.flatMap { block -> [Message] in
            if case .messages(let list) = block { return list }
            return []
        }
        return messages.isEmpty ? nil : messages
    }

    private func currentText(of id: ChatMessage.ID?) -> String {
        // Whatever is still buffered is text the model has already sent. The
        // search-request check reads this, and a request split across a flush
        // boundary would otherwise be missed.
        drainDelta(into: id)
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return "" }
        return turns[index].text
    }

    /// Wipes what the model wrote so the second pass starts on a clean turn.
    /// Leaving "SEARCH: upwork welcome" on screen and appending the real
    /// answer under it would show the reader the plumbing.
    private func clearText(of id: ChatMessage.ID?) {
        // Dropped rather than drained: this is wiping what the model wrote, so
        // anything still in the buffer belongs to the same discarded pass and
        // would otherwise reappear at the top of the real answer.
        stream.pending = ""
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].text = ""
        turns[index].isPending = true
    }

    /// Starts a step, leaving it open. The trail shows the open one pulsing,
    /// which is what tells somebody the app has not stalled -- and unlike a
    /// spinner, it says what it is waiting on.
    private func begin(_ id: ChatMessage.ID?, _ step: TaskStep) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            close(&turns[index].steps)
            turns[index].steps.append(step)
        }
    }

    /// Adds steps that already happened, each one closed.
    ///
    /// These come back from the investigation rather than being written
    /// here, so what the trail claims and what the app did cannot drift
    /// apart. There is no way from this file to add a step that says a
    /// search found twelve emails.
    private func record(_ id: ChatMessage.ID?, _ steps: [TaskStep]) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }), !steps.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            close(&turns[index].steps)
            turns[index].steps += steps.map { step in
                var step = step
                step.isDone = true
                return step
            }
        }
    }

    private func close(_ steps: inout [TaskStep]) {
        for index in steps.indices where !steps[index].isDone {
            steps[index].isDone = true
        }
    }

    /// Appends a fragment as it arrives. No animation on each one: animating
    /// every token turns a smooth stream into a stutter.
    /// One token in from the model.
    ///
    /// 🔴 **This does not touch `turns`.** It used to, and that is what locked
    /// the phone up while an answer was being written.
    ///
    /// `turns` is `@State`, so writing to it invalidates this view -- and this
    /// view is the whole conversation: every previous turn, its markdown, its
    /// cards, its trail. The model streams thirty to eighty tokens a second,
    /// so the app was rebuilding the entire chat that many times a second, on
    /// the main thread, while also running a linear search through `turns` to
    /// find which one to append to. The longer the conversation, the worse it
    /// got, which is why it felt like the phone rather than the app.
    ///
    /// Now fragments land in a plain reference type -- mutating it invalidates
    /// nothing -- and are written across on a timer. Twelve redraws a second
    /// instead of eighty, and text appearing twelve times a second still reads
    /// as it being typed.
    private func appendDelta(_ id: ChatMessage.ID?, _ fragment: String) {
        stream.pending += fragment
        guard !stream.isFlushScheduled else { return }

        stream.isFlushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.streamFlushInterval))
            stream.isFlushScheduled = false
            flushDelta(into: id)
        }
    }

    /// Moves whatever has arrived since the last flush into the turn.
    private func flushDelta(into id: ChatMessage.ID?) {
        let fragment = stream.pending
        stream.pending = ""

        guard !fragment.isEmpty,
              let id, let index = turns.firstIndex(where: { $0.id == id })
        else { return }

        turns[index].text += fragment

        // The trail stays up while what has arrived could still turn into a
        // request to look. "SEARCH: upwork welcome" flashing on screen for
        // the second before the search replaced it was the plumbing showing.
        //
        // Only asked while it is still open: once the text cannot become a
        // request it never can again, because it only grows.
        if turns[index].isPending, !SearchRequest.couldBecomeRequest(turns[index].text) {
            turns[index].isPending = false
        }
    }

    /// Anything buffered but not yet shown, moved across now.
    ///
    /// Called before every read of a turn's text and before the answer is
    /// finished, because a flush that is still sitting on the timer is text
    /// the model sent and the reader has not seen.
    private func drainDelta(into id: ChatMessage.ID?) {
        flushDelta(into: id)
    }

    /// The answer is complete. Blocks land now, so cards do not pop in
    /// underneath text that is still being written -- and if the model wrote
    /// an email, it is lifted out of the prose into a card here.
    ///
    /// `context` is the numbered list the model was reading, in the order it
    /// saw it, so a show block's numbers resolve to the right messages.
    private func finish(
        _ id: ChatMessage.ID?,
        context: [Message],
        searchNote: String? = nil,
        found: [Message] = []
    ) {
        // The last tokens of the answer are usually still on the timer.
        drainDelta(into: id)
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].searchNote = searchNote

        var text = turns[index].text
        var emailDraft: ChatDraft?
        if let (prose, block) = EmailBlock.extract(from: text) {
            emailDraft = makeDraft(from: block, sources: context)
            text = prose.isEmpty ? "Here's the email. Send it, or edit it first." : prose
        }

        // Tiles, charts, and the emails themselves, where the model asked for
        // them. The app decides neither which questions deserve structure nor
        // which emails an answer is about. "The last email I got" used to be
        // a correct sentence with six unrelated rows under it, because the
        // app attached what it had rather than what was asked for.
        let structured = AnswerFences.read(from: text, messages: context)

        close(&turns[index].steps)
        withAnimation(.easeOut(duration: 0.25)) {
            turns[index].text = structured.prose
            turns[index].blocks = structured.blocks
            turns[index].draft = emailDraft
            // What the search turned up, and only when there was one. The
            // dozen messages retrieval picked were never the answer; listing
            // them under it made every reply look like it had found twelve
            // emails, and under "nothing matched" it looked like a lie.
            turns[index].sources = searchNote == nil ? [] : found
            turns[index].isPending = false
        }

        for note in structured.memories {
            remember(note)
        }
    }

    // MARK: - Remembering

    /// The model said this was worth keeping, and which kind of thing it is.
    /// Shown as a receipt rather than a sentence, because "I'll remember
    /// that" with nothing behind it is the oldest lie an assistant tells.
    /// A duplicate is dropped quietly: the model has already said it has it,
    /// and it does.
    private func remember(_ note: MemoryNote) {
        guard let saved = memory.remember(note.text, kind: note.kind, until: note.until) else { return }

        Analytics.record(.memorySaved, [
            "length": .int(saved.text.count),
            "kind": .string(saved.kind.rawValue),
            "expires": .bool(saved.until != nil),
        ])

        var detail = "I'll keep this in mind. You can remove it in Settings."
        if let until = saved.until {
            detail = "I'll keep this in mind until \(until.formatted(.dateTime.day().month(.wide))). You can remove it in Settings."
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            turns.append(.did(ChatReceipt(
                symbol: "brain",
                title: saved.text,
                detail: detail,
                undo: []
            )))
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
            finish(id, context: sources)
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
        turns.append(.working(.writing(to: name)))
        let pendingID = turns.last?.id

        isWorking = true
        defer { isWorking = false }

        do {
            // Everything the app already knows about this conversation and
            // the person on the other end of it. A reply that asks for
            // something they sent last week, or repeats a promise already
            // made, is the app knowing less than the person reading it.
            let result = try await AIService.draft(
                replyingTo: original,
                instruction: instruction,
                tone: user.tonePreference,
                thread: original.map { mail.threadSummary(for: $0) } ?? "",
                standing: original.flatMap { mail.standing(for: $0.sender.address) }?.described() ?? ""
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
            if let original = pending.replyingTo { mail.markReplied(original.id) }

            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                turns[index].draft?.status = .sent
            }
            let recipient = pending.to.name.isEmpty ? pending.to.address : pending.to.name
            turns.append(.say("Sent to \(recipient)."))
            Analytics.record(.draftSent, [
                "was_reply": .bool(pending.replyingTo != nil),
                "length": .int(pending.body.count),
            ])
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
        Analytics.record(.draftDiscarded)
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
    .environment(AIMemory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-memory.json")))
}
