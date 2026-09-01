import SwiftUI

/// One email, shown in the conversation.
///
/// The sibling of `EmailDraftCard`, and deliberately built from the same
/// pieces: the same corner radius, the same hairlines, the same envelope
/// fields. One card is an email Maily wrote and is waiting to send; this one
/// is an email somebody sent, which cannot be edited and does not need to be.
/// They should read as two states of one object rather than two components.
///
/// Only ever used for a single result. When Maily has several to offer, a
/// stack of these would be a wall: those go to `AnswerMessageList`, which is
/// a row each, and the person picks one.
struct EmailPeekCard: View {
    let message: Message

    var body: some View {
        NavigationLink(value: message.id) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                hairline
                subjectRow
                hairline

                Text(snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                footer
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
            }
        }
        .buttonStyle(BouncyButtonStyle())
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            SenderAvatar(contact: message.sender, size: 38, isMuted: message.isRead)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.sender.name.isEmpty ? message.sender.address : message.sender.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(message.listDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let tag = message.topPriority {
                Image(systemName: tag.systemImage)
                    .font(.caption)
                    .foregroundStyle(tag.color)
                    .accessibilityLabel(tag.title)
            }
            if message.hasAttachment {
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subjectRow: some View {
        Text(message.subject.isEmpty ? "(No subject)" : message.subject)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Open")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            if !message.isRead {
                Text("Unread")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(uiColor: .separator).opacity(0.35))
            .frame(height: 0.5)
    }

    /// The summary when the model wrote one, the opening of the message
    /// otherwise. Whitespace collapsed, because a quoted reply chain arrives
    /// as a column of blank lines and four of them is not a preview.
    private var snippet: String {
        let source = message.aiSummary ?? message.body
        let flattened = source
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "No content." : String(flattened.prefix(280))
    }
}
