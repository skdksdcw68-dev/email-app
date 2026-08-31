import SwiftUI
import UIKit

/// The chat input, ported from Drobe's `chat-input-bar.tsx`.
///
/// The structural point I kept missing: this is a panel, not a capsule with
/// controls tucked inside it. Text on top, a toolbar row underneath, always,
/// in both states. That is what makes the resting height look deliberate and
/// what lets it grow without the buttons being pushed anywhere.
///
/// Metrics are Drobe's: 20pt corner, 16pt padding, 12pt between rows, 15/20
/// text from one line up to 120pt then scrolling, and a 32pt round send.
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

    private var hasRequest: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool { hasRequest && !isWorking }

    var body: some View {
        VStack(spacing: 0) {
            if showsActions { actionMenu }

            panel
                .padding(.horizontal, 14)
                .padding(.top, showsActions ? 4 : 8)
                .padding(.bottom, 8)
        }
        .background(.regularMaterial)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showsActions)
        .sensoryFeedback(.impact(weight: .medium), trigger: isWorking)
    }

    // MARK: - The panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(isWorking ? "Maily is typing…" : "Ask Maily", text: $text, axis: .vertical)
                .font(.system(size: 15))
                .lineSpacing(4)
                // One line at rest, growing to six, then scrolling inside
                // itself. No fixed height: a pinned height makes every state
                // other than the resting one wrong.
                .lineLimit(1...6)
                .focused($isFocused)

            HStack(alignment: .center, spacing: 0) {
                plusButton
                Spacer(minLength: 0)
                if isFocused { dismissButton }
                sendButton
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            hasRequest ? Color.accentColor.opacity(0.3) : Color(uiColor: .separator).opacity(0.35),
                            lineWidth: 0.5
                        )
                }
        }
        .shadow(color: hasRequest ? Color.accentColor.opacity(0.14) : .clear, radius: 8, y: 2)
        .animation(.easeInOut(duration: 0.2), value: hasRequest)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isFocused)
    }

    /// The same button closes what it opened, so there is never a second,
    /// differently placed way out of the menu.
    private var plusButton: some View {
        Button {
            showsActions.toggle()
        } label: {
            Image(systemName: showsActions ? "xmark" : "plus")
                .font(.system(size: showsActions ? 18 : 22, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel(showsActions ? "Close menu" : "More")
    }

    private var dismissButton: some View {
        Button {
            isFocused = false
            showsActions = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Hide keyboard")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(canSend ? Color.white : Color.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(
                        canSend
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(Color.primary.opacity(0.2))
                    )
                }
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(!canSend)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: canSend)
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
/// small, fast scale under the finger. "It bounces when you tap it" is most of
/// what makes a control feel native.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
