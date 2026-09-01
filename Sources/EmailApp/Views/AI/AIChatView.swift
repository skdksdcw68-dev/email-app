import SwiftUI
import UIKit

/// The chat, pushed from the AI tab.
///
/// Entirely SwiftUI for content: the bubbles, the thinking dots and the
/// composer are all native views. Positioning the composer is the one job
/// handed to UIKit -- `KeyboardAttachedBar` pins it to the keyboard's layout
/// guide so it moves on the keyboard's own curve and tracks an interactive
/// dismissal exactly, which SwiftUI's safe-area machinery could not do.
///
/// Questions are routed before anything is spent: what the mailbox can
/// settle on its own is answered instantly on the device as structure
/// (tiles, cards, a chart); everything else goes to the model with a
/// device-side retrieval digest and streams back as prose with sources.
/// See `MailStore.localAnswer(for:)` for the full ladder.
struct AIChatView: View {
    @Environment(MailStore.self) private var mail

    @State private var turns: [ChatMessage] = []
    @State private var draft = ""
    @State private var isWorking = false
    @State private var showsActions = false
    /// Reported by the attached bar, so the conversation leaves room for it.
    /// Starts at the resting capsule height so the first frame is right.
    @State private var barHeight: CGFloat = 54

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if turns.isEmpty {
                        AIChatWelcome(
                            briefing: mail.inboxStatus,
                            followUps: mail.followUps
                        )
                        .padding(.top, 4)
                        .transition(.opacity)
                    }

                    ForEach(turns) { turn in
                        ChatTurnView(turn: turn)
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
                showsActions = false
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
                        showsActions: $showsActions,
                        isWorking: isWorking,
                        onSend: send,
                        onAction: handleAction
                    )
                }
                // Full-bleed on purpose: if SwiftUI shrank this for the
                // keyboard, the bar would be back to following SwiftUI's
                // layout instead of UIKit's guide.
                .ignoresSafeArea()
            }
        }
        .keyboardDismissable()
        .navigationTitle("Maily")
        .navigationBarTitleDisplayMode(.inline)
        // Pushed page, so the tab bar goes.
        .hidesTabBar()
        .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        withAnimation { turns = [] }
                    } label: {
                        Label("Clear conversation", systemImage: "trash")
                    }
                    .disabled(turns.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    // MARK: - Asking

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        ask(question)
    }

    private func handleAction(_ action: ChatComposer.Action) {
        switch action {
        case .whatNeedsReply: ask("What do I need to reply to?")
        case .whoIsWaiting:   ask("Who am I keeping waiting?")
        case .findSomething:  break // The composer owns focus and handles this itself.
        }
    }

    private func ask(_ question: String) {
        dismissKeyboard()
        showsActions = false
        turns.append(.user(question))

        // Level 1: the mailbox can answer this itself. Instant, free, and
        // structured instead of prose.
        if let local = mail.localAnswer(for: question) {
            turns.append(.local(local))
            return
        }

        // Level 2: the model, with device-side retrieval.
        turns.append(.thinking)
        let pendingID = turns.last?.id

        Task {
            isWorking = true
            defer { isWorking = false }

            let context = mail.context(for: question)
            do {
                // Streamed, so the answer types itself out instead of landing
                // whole after a long silence.
                try await AIService.askStreaming(question: question, context: context) { fragment in
                    appendDelta(pendingID, fragment)
                }
                finish(pendingID, sources: context)
            } catch {
                replace(pendingID, with: error.localizedDescription, sources: [], failed: true)
            }
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

    private func replace(_ id: ChatMessage.ID?, with text: String, sources: [Message], failed: Bool) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            turns[index].text = text
            turns[index].sources = failed ? [] : sources
            turns[index].isPending = false
            turns[index].failed = failed
        }
    }
}

#Preview {
    NavigationStack {
        AIChatView()
    }
    .environment(MailStore.connected())
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
