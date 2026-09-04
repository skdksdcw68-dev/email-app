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

                    // Thinking, while it is still thinking, is the dot on its
                    // own. "Working out what would answer this" is the app
                    // narrating that it has not started yet -- and it sat
                    // above the answer for the whole time the answer was
                    // being written. The steps that report real work still
                    // say what they did, and this one says so once it is
                    // done and the trail is being read back.
                    if !isThinkingNow(step) {
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(step.isDone ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A thinking step that has not finished. There is nothing to report yet,
    /// so the pulse reports it.
    private func isThinkingNow(_ step: TaskStep) -> Bool {
        step.kind == .understanding && !step.isDone
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
            // Was 7pt shrinking to 0.55 -- under four points at the bottom of
            // its breath, which is smaller than the full stop at the end of
            // the line beside it. This is the only thing on screen saying the
            // app is still working, so it has to be seen without looking for
            // it.
            //
            // Bigger, and it now breathes between 0.8 and 1.1 rather than
            // 0.55 and 1: the movement reads as a pulse instead of the dot
            // repeatedly almost vanishing.
            .frame(width: 11, height: 11)
            .scaleEffect(isUp ? 1.1 : 0.8)
            .opacity(isUp ? 1 : 0.55)
            // A fixed box, so the row does not shift as it breathes.
            .frame(width: 14, height: 14)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
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
