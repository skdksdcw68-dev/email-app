import SwiftUI
import UIKit

/// The chat, pushed from the AI tab.
///
/// Entirely SwiftUI: the bubbles, the thinking dots, the composer that grows
/// into a card when focused and the attachment menu that slides up over it are
/// all native views. No web content anywhere.
struct AIChatView: View {
    @Environment(MailStore.self) private var mail

    @State private var turns: [ChatMessage] = []
    @State private var draft = ""
    @State private var isWorking = false
    @State private var showsActions = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if turns.isEmpty {
                        AIChatWelcome(
                            briefing: mail.inboxStatus,
                            followUps: mail.followUps,
                            onPick: { ask($0) }
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
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { _, _ in
                guard let last = turns.last else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .keyboardDismissable()
        .navigationTitle("Maily")
        .navigationBarTitleDisplayMode(.inline)
        // Pushed page, so the tab bar goes.
        .toolbar(.hidden, for: .tabBar)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(
                text: $draft,
                isFocused: $isInputFocused,
                showsActions: $showsActions,
                isWorking: isWorking,
                onSend: send,
                onAction: handleAction
            )
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
        case .findSomething:  isInputFocused = true
        }
    }

    private func ask(_ question: String) {
        isInputFocused = false
        showsActions = false
        turns.append(.user(question))
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
