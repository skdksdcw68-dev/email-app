import SwiftUI
import UIKit

/// Shown while the first three months of mail come down.
///
/// The wording is driven entirely by `ImportProgress`, which is driven by real
/// counts. There is no timer here and nothing says "almost there" before it is.
struct ImportingMailView: View {
    let progress: ImportProgress
    /// Whether there is anywhere to go. True when this is a mailbox being
    /// added to an app already in use; false during onboarding, where the
    /// import *is* the screen and leaving it would land on nothing.
    var canLeave = false

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ring

            VStack(spacing: 8) {
                Text(progress.title)
                    .font(.title3.weight(.bold))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: progress.title)

                Text(progress.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: progress.detail)
            }
            .padding(.top, 32)
            .padding(.horizontal, 40)

            Spacer()

            footer
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .onAppear { pulse = true }
    }

    /// Said plainly, because otherwise somebody sits and watches it.
    ///
    /// A progress ring with no other instruction reads as "do not touch
    /// this", and a big mailbox can take minutes. It is genuinely safe to
    /// walk away: the work is not owned by this screen, and `ImportLedger`
    /// records what is left so leaving the app entirely resumes rather than
    /// starting again.
    @ViewBuilder
    private var footer: some View {
        if canLeave && progress.isRunning {
            VStack(spacing: 6) {
                Label("Safe to close", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                Text("This carries on in the background, and picks up where it left off if you leave the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        } else {
            Text("You can use Maily without a connection once this is done.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    /// A determinate ring once there is a real fraction, and a breathing
    /// circle before that -- rather than a bar inching along on a guess.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 10)

            if let fraction = progress.fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(pulse ? 360 : 0))
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: pulse
                    )
            }

            Image(systemName: glyph)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 132, height: 132)
        .overlay(alignment: .bottom) {
            if let fraction = progress.fraction, progress.isRunning {
                Text("\(Int(fraction * 100))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(y: 26)
            }
        }
    }

    private var glyph: String {
        switch progress {
        case .connecting: "link"
        case .counting: "magnifyingglass"
        case .importing: "arrow.down.circle"
        case .saving: "internaldrive"
        case .finished: "checkmark.circle.fill"
        case .idle: "envelope"
        }
    }
}

#Preview("Counting") {
    ImportingMailView(progress: .counting)
}

#Preview("Importing") {
    ImportingMailView(progress: .importing(done: 120, total: 480))
}

#Preview("Almost there") {
    ImportingMailView(progress: .importing(done: 440, total: 480))
}
