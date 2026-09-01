import SwiftUI
import UIKit

/// The chat input, in ChatGPT's shape and with ChatGPT's motion.
///
/// A single-row capsule, 48pt at rest: plus on the left, the field in the
/// middle, send on the right, all on one line. It never becomes a panel.
/// Focus widens it from 34pt side margins to 12pt, in step with the keyboard
/// rising; a new line grows it upward with the buttons pinned to the bottom
/// edge. The earlier two-row panel had the expanded state as its resting
/// state, which is why it never read as the real thing.
///
/// Positioning is not this view's job. `KeyboardAttachedBar` pins it to the
/// keyboard through UIKit's layout guide; nothing here animates position.
struct ChatComposer: View {
    @Binding var text: String
    @Binding var showsActions: Bool
    let isWorking: Bool
    let onSend: () -> Void
    let onAction: (Action) -> Void

    /// Owned here rather than passed in: focus has to live on the same side
    /// of the UIKit hosting boundary as the field it drives.
    @FocusState private var isFocused: Bool

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

    /// Wide as soon as the field is focused, not only once there is text.
    /// Measured off ChatGPT: it widens *during* the keyboard's rise, so the
    /// two read as one gesture; waiting for the first character made ours a
    /// separate, later event.
    private var isExpanded: Bool { isFocused || hasRequest }

    var body: some View {
        VStack(spacing: 10) {
            if showsActions {
                actionMenu
                    .padding(.horizontal, 12)
            }

            capsule
                // Narrow at rest, full width in use. Measured off ChatGPT:
                // ~360pt idle, ~404pt focused or typing.
                .padding(.horizontal, isExpanded ? 12 : 34)
        }
        .padding(.top, 6)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: showsActions)
        .animation(.easeOut(duration: 0.22), value: isExpanded)
        .sensoryFeedback(.impact(weight: .light), trigger: showsActions)
        .sensoryFeedback(.impact(weight: .medium), trigger: isWorking)
    }

    // MARK: - The capsule

    private var capsule: some View {
        HStack(alignment: .bottom, spacing: 6) {
            plusButton

            TextField(isWorking ? "Maily is typing…" : "Ask Maily", text: $text, axis: .vertical)
                .font(.system(size: 16))
                .lineSpacing(3)
                // One line at rest, growing to six, then scrolling inside
                // itself. The buttons stay on the bottom edge while it grows.
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 7)

            sendButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    // Neutral in every state. A border that turns blue when
                    // there is text is a custom-app tell; the real thing only
                    // brightens a touch on focus.
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            Color(uiColor: .separator).opacity(isFocused ? 0.7 : 0.45),
                            lineWidth: 0.5
                        )
                }
        }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // A new line grows the capsule smoothly instead of snapping it a
        // line taller. Keyed to the text because that is the only thing that
        // changes the line count; on an ordinary keystroke nothing moves, so
        // nothing animates.
        .animation(.easeOut(duration: 0.18), value: text)
    }

    /// The same button closes what it opened, so there is never a second,
    /// differently placed way out of the menu.
    private var plusButton: some View {
        Button {
            showsActions.toggle()
        } label: {
            Image(systemName: showsActions ? "xmark" : "plus")
                .font(.system(size: showsActions ? 17 : 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel(showsActions ? "Close menu" : "More")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
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
        .buttonStyle(PressButtonStyle())
        .disabled(!canSend)
        // A quick fade, not a bounce. The enable state flips on every
        // keystroke at the edge of an empty field; a spring there wobbles.
        .animation(.easeOut(duration: 0.15), value: canSend)
        .accessibilityLabel("Send")
    }

    // MARK: - The plus menu

    private var actionMenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(Action.allCases.enumerated()), id: \.offset) { index, action in
                Button {
                    showsActions = false
                    if action == .findSomething {
                        // Focus is ours to give, so this one never leaves.
                        isFocused = true
                    } else {
                        onAction(action)
                    }
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
                .buttonStyle(PressButtonStyle())

                if index < Action.allCases.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

/// The press feel of a system control: a small, fast dip with no
/// oscillation. This is what the composer's buttons use -- ChatGPT's press
/// feedback is a nod, not a bounce.
struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The bigger, springier press used on tiles and cards, where a visible
/// bounce is the point. Too much for a 32pt icon button; right for a 62pt
/// option tile.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
