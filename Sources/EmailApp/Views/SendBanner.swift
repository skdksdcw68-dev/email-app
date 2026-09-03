import SwiftUI

/// The strip that says a message is on its way, and offers to stop it.
///
/// One of these for the whole app, mounted over the tab bar rather than
/// inside any screen. The compose sheet is closed by the time it appears --
/// that is the point of holding the send at all -- so it has to live
/// somewhere the sheet cannot take with it.
///
/// It sits above the tab bar rather than at the top because the send button
/// is at the top: a confirmation that appears where the finger just left is
/// a confirmation nobody reads.
struct SendBanner: View {
    @Environment(MailStore.self) private var mail

    /// Redrawn every second so the count actually counts. Only running while
    /// something is held, so it is not a timer the app pays for all day.
    @State private var now = Date.now

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            if let held = mail.heldSend {
                strip(held)
            }
            if let failure = mail.sendFailure {
                failed(failure)
            }
        }
        .padding(.horizontal, 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: mail.heldSend)
        .animation(.easeOut(duration: 0.2), value: mail.sendFailure)
        .onReceive(tick) { now = $0 }
    }

    // MARK: - On its way

    private func strip(_ held: MailStore.HeldSend) -> some View {
        HStack(spacing: 12) {
            // The countdown ring, so the window is visible rather than
            // something you have to feel out.
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: remaining(held))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .animation(.linear(duration: 1), value: remaining(held))

            VStack(alignment: .leading, spacing: 1) {
                Text("Sending to \(held.recipient)")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(held.subject)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button("Undo") { mail.cancelHeldSend() }
                .font(.footnote.weight(.bold))
                .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .darkGray))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// How much of the window is left, 1 down to 0.
    private func remaining(_ held: MailStore.HeldSend) -> CGFloat {
        let total = TimeInterval(MailStore.undoWindow.components.seconds)
        guard total > 0 else { return 0 }
        let left = held.sendsAt.timeIntervalSince(now)
        return CGFloat(min(max(left / total, 0), 1))
    }

    // MARK: - It didn't go

    /// The one place a failed send can still be reported. By the time this
    /// matters the compose sheet is long gone, and a message that quietly
    /// failed is the worst thing a mail app can do.
    private func failed(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                mail.sendFailure = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .systemRed))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
