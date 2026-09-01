import SwiftUI
import UIKit

/// What the plus button offers.
enum ChatOption: Hashable {
    case needsReply
    case waiting
    case urgent
    case write
    case summary
    case deadlines
    case clear
}

/// The plus button's sheet, in Perplexity's shape: a title with an X, a row
/// of four square tiles, one quiet line of caption, then a short list of
/// rows with a subtitle each. Our actions, their layout.
///
/// A real sheet rather than a card floating over the composer. The sheet is
/// the platform's own control, so it comes with the drag handle, the corner
/// radius and the spring for free, and it gets out of the way the same way
/// every other sheet does.
struct ChatOptionsSheet: View {
    let onPick: (ChatOption) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Options")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                }
                .buttonStyle(PressButtonStyle())
                .accessibilityLabel("Close")
            }
            .padding(.top, 22)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            HStack(spacing: 10) {
                tile(.needsReply, symbol: "arrowshape.turn.up.left", title: "Replies")
                tile(.waiting, symbol: "clock.arrow.circlepath", title: "Waiting")
                tile(.urgent, symbol: "bolt", title: "Urgent")
                tile(.write, symbol: "square.and.pencil", title: "Write")
            }
            .padding(.horizontal, 20)

            Text("Answers come from your mailbox, on this phone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            VStack(spacing: 0) {
                row(.summary, symbol: "sparkles",
                    title: "Summarise my mail", subtitle: "What matters, in three lines")
                row(.deadlines, symbol: "calendar",
                    title: "Deadlines this week", subtitle: "Dates and commitments in your mail")
                row(.clear, symbol: "trash",
                    title: "Clear conversation", subtitle: nil, isDestructive: true)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
    }

    private func pick(_ option: ChatOption) {
        dismiss()
        onPick(option)
    }

    private func tile(_ option: ChatOption, symbol: String, title: String) -> some View {
        Button {
            pick(option)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
        }
        .buttonStyle(BouncyButtonStyle())
    }

    private func row(
        _ option: ChatOption,
        symbol: String,
        title: String,
        subtitle: String?,
        isDestructive: Bool = false
    ) -> some View {
        Button {
            pick(option)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressButtonStyle())
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            ChatOptionsSheet { _ in }
        }
}
