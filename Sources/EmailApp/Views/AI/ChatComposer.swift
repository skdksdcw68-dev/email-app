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
/// The plus button is not this view's menu either: it asks the owner to
/// present the options sheet, which is a real sheet.
struct ChatComposer: View {
    @Binding var text: String
    @Binding var showsOptions: Bool
    let isWorking: Bool
    /// Bumped by the owner after a send. The field is rebuilt under a new
    /// identity, which is the one reliable way to make a vertical TextField
    /// drop back to one line -- clearing its text while it was three lines
    /// tall left it three lines tall, with the placeholder sitting in the
    /// space the question used to take.
    let resetToken: Int
    /// Bumped by the owner to put the cursor in the field, since focus has
    /// to live on this side of the UIKit hosting boundary.
    let focusToken: Int
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

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
        capsule
            // Narrow at rest, full width in use. Measured off ChatGPT:
            // ~360pt idle, ~404pt focused or typing.
            .padding(.horizontal, isExpanded ? 12 : 34)
            .padding(.top, 6)
            .animation(.easeOut(duration: 0.22), value: isExpanded)
            .sensoryFeedback(.impact(weight: .light), trigger: showsOptions)
            .sensoryFeedback(.impact(weight: .medium), trigger: isWorking)
            .onChange(of: focusToken) { _, _ in
                isFocused = true
            }
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
                .id(resetToken)

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

    private var plusButton: some View {
        Button {
            isFocused = false
            showsOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel("Options")
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
