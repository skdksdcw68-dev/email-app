import SwiftUI
import UIKit

/// The AI tab, as a conversation.
///
/// This is the tab root rather than a pushed page, which is why the tab bar
/// stays underneath it. Before the first question it shows the briefing and
/// what is outstanding; after that it is a thread.
///
/// Entirely SwiftUI. No web view, no bridge -- the bubbles, the input bar and
/// the thinking state are all native, so it behaves like the rest of the app
/// and keeps working offline for everything that does not need the model.
struct AIChatView: View {
    @Environment(MailStore.self) private var mail

    @State private var turns: [ChatMessage] = []
    @State private var draft = ""
    @State private var isWorking = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if turns.isEmpty {
                            AIChatWelcome(
                                briefing: mail.inboxStatus,
                                followUps: mail.followUps,
                                onPick: { ask($0) }
                            )
                            .padding(.top, 4)
                        }

                        ForEach(turns) { turn in
                            ChatTurnView(turn: turn)
                                .id(turn.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) { _, _ in
                    // Follow the conversation down as it grows.
                    if let last = turns.last {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("Maily AI")
            .navigationBarTitleDisplayMode(.inline)
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
                        Label("Options", systemImage: "ellipsis")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                // Grows with the text, up to a point, then scrolls -- the same
                // shape every chat input on the platform has.
                TextField("Ask about your email", text: $draft, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background {
                            Circle().fill(canSend ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.trailing, 7)
                .padding(.bottom, 7)
            }
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Asking

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        ask(question)
    }

    private func ask(_ question: String) {
        isInputFocused = false
        turns.append(.user(question))
        turns.append(.thinking)
        let pendingID = turns.last?.id

        Task {
            isWorking = true
            defer { isWorking = false }

            let context = mail.context(for: question)

            do {
                let result = try await AIService.ask(question: question, context: context)
                replace(pendingID, with: result.answer, sources: context, failed: false)
            } catch {
                replace(pendingID, with: error.localizedDescription, sources: [], failed: true)
            }
        }
    }

    private func replace(_ id: ChatMessage.ID?, with text: String, sources: [Message], failed: Bool) {
        guard let id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].text = text
        turns[index].sources = failed ? [] : sources
        turns[index].isPending = false
        turns[index].failed = failed
    }
}

#Preview {
    AIChatView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}
