import SwiftUI
import UIKit

/// The chat input.
///
/// At rest it is a pill. Focused, it grows into a card with the controls along
/// the bottom, which is the shape every good chat input on iOS has -- it gives
/// a long question room to be read back before it is sent, and it makes the
/// transition into typing feel like something happened.
///
/// The `+` opens a menu above the field rather than a sheet, so the keyboard
/// stays up and the thing you were typing stays visible.
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

    private var isExpanded: Bool { isFocused || !text.isEmpty }

    private var canSend: Bool {
        !isWorking && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsActions { actionMenu }

            composer
                .padding(.horizontal, 14)
                .padding(.top, showsActions ? 4 : 8)
                .padding(.bottom, 8)
        }
        .background(.bar)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showsActions)
    }

    // MARK: - The field

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Ask Maily", text: $text, axis: .vertical)
                .font(.subheadline)
                // At rest one line; focused it opens up so a long question is
                // readable before it is sent.
                .lineLimit(isExpanded ? 6...12 : 1...1)
                .frame(minHeight: isExpanded ? 96 : 0, alignment: .topLeading)
                .focused($isFocused)
                .padding(.horizontal, 16)
                .padding(.top, isExpanded ? 14 : 11)
                .padding(.bottom, isExpanded ? 6 : 11)

            if isExpanded {
                HStack(spacing: 0) {
                    plusButton
                    Spacer(minLength: 0)
                    dismissButton
                    sendButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            // Collapsed, the controls sit inside the pill instead of below it.
            if !isExpanded {
                HStack(spacing: 4) {
                    plusButton
                    sendButton
                }
                .padding(.trailing, 6)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: isExpanded ? 24 : 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: isExpanded ? 24 : 22, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(isExpanded ? 0.06 : 0), radius: 10, y: 3)
        }
    }

    private var plusButton: some View {
        Button {
            if isFocused && !showsActions {
                // Keep the keyboard: the menu sits above it.
                showsActions = true
            } else {
                showsActions.toggle()
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(showsActions ? 45 : 0))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel("More")
    }

    /// Puts the keyboard away. There was no way to do it at all while talking
    /// to the AI, which left the chat half-covered with no way back.
    private var dismissButton: some View {
        Button {
            isFocused = false
            showsActions = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel("Hide keyboard")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(canSend ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                }
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(!canSend)
        .padding(.trailing, 4)
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
        .background(Color(uiColor: .systemBackground))
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
