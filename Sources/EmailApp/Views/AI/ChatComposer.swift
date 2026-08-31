import SwiftUI
import UIKit

/// The chat input.
///
/// One line at rest, growing as you type up to five, then scrolling inside
/// itself. An earlier version forced a tall card the moment the field was
/// focused, which meant a two word question sat in a mostly empty box and the
/// list jumped every time the keyboard appeared. Growing with the text is both
/// calmer and what every good chat input actually does.
///
/// The `+` opens a menu above the field rather than a sheet, so the keyboard
/// stays up and what you were typing stays visible.
struct ChatComposer: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    @Binding var showsActions: Bool
    let isWorking: Bool
    let onSend: () -> Void
    let onAction: (Action) -> Void

    enum Action: CaseIterable {
        case whatNeedsReply
        case whoIsWaiting
        case findSomething

        var title: String {
            switch self {
            case .whatNeedsReply: "What needs a reply"
            case .whoIsWaiting:   "Who is waiting on me"
            case .findSomething:  "Find something"
            }
        }

        var symbol: String {
            switch self {
            case .whatNeedsReply: "arrowshape.turn.up.left"
            case .whoIsWaiting:   "clock.arrow.circlepath"
            case .findSomething:  "magnifyingglass"
            }
        }
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool { !isWorking && hasText }

    var body: some View {
        VStack(spacing: 0) {
            if showsActions { actionMenu }

            HStack(alignment: .bottom, spacing: 8) {
                plusButton

                field

                if isFocused { dismissButton }
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Frosted, so the conversation blurs underneath rather than being cut
        // off by an opaque bar.
        .background(.regularMaterial)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showsActions)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
        // The click on send, which is most of what makes a control feel real.
        .sensoryFeedback(.impact(weight: .medium), trigger: isWorking)
    }

    // MARK: - The field

    private var field: some View {
        TextField("Ask Maily", text: $text, axis: .vertical)
            .font(.subheadline)
            // Grows to five lines, then scrolls inside itself.
            .lineLimit(1...5)
            .focused($isFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                hasText ? Color.accentColor.opacity(0.35) : Color(uiColor: .separator).opacity(0.4),
                                lineWidth: 0.5
                            )
                    }
            }
            // A soft glow only while there is something to send, so the field
            // reads as live rather than as a permanently lit box.
            .shadow(color: hasText ? Color.accentColor.opacity(0.18) : .clear, radius: 8, y: 2)
            .animation(.easeInOut(duration: 0.2), value: hasText)
    }

    private var plusButton: some View {
        Button {
            showsActions.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(showsActions ? 45 : 0))
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel("More")
    }

    /// Puts the keyboard away. Only present while it is up, so it does not sit
    /// there as a dead control.
    private var dismissButton: some View {
        Button {
            isFocused = false
            showsActions = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Hide keyboard")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(canSend ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                }
                // Comes alive the moment there is something to send.
                .scaleEffect(canSend ? 1 : 0.88)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: canSend)
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(!canSend)
        .padding(.bottom, 2)
        .accessibilityLabel("Send")
    }

    // MARK: - The plus menu

    private var actionMenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(Action.allCases.enumerated()), id: \.offset) { index, action in
                Button {
                    showsActions = false
                    onAction(action)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: action.symbol)
                            .font(.body)
                            .frame(width: 26)
                        Text(action.title)
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(BouncyButtonStyle())

                if index < Action.allCases.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

/// The press feel iOS controls have and SwiftUI's plain style does not: a
/// small, fast scale under the finger. Applied to the chat controls because
/// "it bounces when you tap it" is most of what makes a native app feel native.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
