import SwiftUI

/// The work, while it is happening.
///
/// A single line saying "Thinking" for eleven seconds is the same screen
/// whether the app is searching a mailbox three times or has stalled, and
/// the reader cannot tell which. This is the alternative every good agent
/// has converged on: the steps arrive as they are taken, each one ticks when
/// it is finished, and the open one pulses.
///
/// Nothing here composes its own wording. Every line is a `TaskStep`, and
/// those can only be derived from the thing they describe, so the trail
/// cannot claim work that did not happen. That is the difference between
/// showing your work and animating a spinner with ambitions.
struct TaskTrail: View {
    let steps: [TaskStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    marker(for: step)
                        .frame(width: 14, height: 14)

                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(step.isDone ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func marker(for step: TaskStep) -> some View {
        if step.isDone {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.accentColor)
        } else {
            PulsingDot()
        }
    }
}

/// The one step still running. Deliberately not a spinner: a spinner says
/// "waiting", and the line beside this already says what for.
private struct PulsingDot: View {
    @State private var isUp = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .scaleEffect(isUp ? 1 : 0.55)
            .opacity(isUp ? 1 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isUp = true
                }
            }
    }
}

/// The same trail after the answer has landed, folded to one line.
///
/// Kept rather than thrown away: an answer that took two searches and an
/// answer that took none look identical once the work is gone, and only one
/// of them deserves to be trusted. Folded rather than shown, because the
/// answer is what the person came for and the receipt should not outrank it.
struct TaskTrailSummary: View {
    let steps: [TaskStep]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.indent")
                        .font(.caption2)
                    Text(TaskStep.summary(of: steps))
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide what Maily did" : "Show what Maily did")

            if isExpanded {
                TaskTrail(steps: steps)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
