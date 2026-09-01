import SwiftUI

/// One message in a list. Shared by the inbox and anywhere else messages are
/// listed, so the row looks identical everywhere.
///
/// Three lines: who, what, and the opening of it. Nothing else -- no chevron,
/// no card, and deliberately no tag badge. A label on every single row is not
/// information, it is wallpaper; the tags live on the filter pills above,
/// where they can actually be acted on. Unread state is carried by weight
/// alone -- bold sender, bold subject. The blue dot restated what the bold
/// text already said, and a mark on most rows of a busy inbox is noise.
struct MessageRow: View {
    let message: Message
    /// How many messages are in this conversation. 1 hides the count.
    var threadCount: Int = 1
    /// Words to mark, when this row is a search result. Empty everywhere else,
    /// which is the common case and costs nothing.
    var highlight: [String] = []

    /// For a search result, the piece of the body the match is actually in.
    ///
    /// The opening of an email is usually "Hi Abel, hope you are well", which
    /// tells a searcher nothing about why this row is in front of them. When
    /// a term appears in the body, the row shows the sentence it appears in
    /// instead.
    private var matchedPreview: String {
        guard !highlight.isEmpty else { return message.preview }

        let body = message.body
        guard let hit = highlight.lazy.compactMap({ term in
            body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
        }).first else { return message.preview }

        let start = body.index(hit.lowerBound, offsetBy: -40, limitedBy: body.startIndex)
            ?? body.startIndex
        let end = body.index(hit.upperBound, offsetBy: 90, limitedBy: body.endIndex)
            ?? body.endIndex

        let snippet = body[start..<end]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return start > body.startIndex ? "…\(snippet)" : snippet
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(contact: message.sender, size: 44, isMuted: message.isRead)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.sender.name)
                        .font(.subheadline)
                        .fontWeight(message.isRead ? .medium : .semibold)
                        .lineLimit(1)

                    if threadCount > 1 {
                        Text("\(threadCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                    }

                    Spacer(minLength: 4)

                    Text(message.listDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(Highlight.mark(message.subject, terms: highlight))
                    .font(.subheadline)
                    .fontWeight(message.isRead ? .regular : .bold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Highlight.mark(matchedPreview, terms: highlight))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if message.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

            }
        }
        .padding(.vertical, 6)
    }
}

/// Leading/trailing swipe actions for a message. Kept beside the row so every
/// list offers the same gestures.
struct MessageSwipeActions: ViewModifier {
    let message: Message
    @Environment(MailStore.self) private var store

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    store.markRead(message.id, !message.isRead)
                } label: {
                    Label(
                        message.isRead ? "Unread" : "Read",
                        systemImage: message.isRead ? "envelope.badge" : "envelope.open"
                    )
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    store.delete(message.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    store.toggleFlag(message.id)
                } label: {
                    Label("Flag", systemImage: "flag")
                }
                .tint(.orange)
            }
    }
}

extension View {
    func messageSwipeActions(for message: Message) -> some View {
        modifier(MessageSwipeActions(message: message))
    }
}

/// A row-shaped placeholder, used while the first page is still loading so
/// the list can be scrolled before any mail has arrived.
struct MessageRowSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 44, height: 44)
                .shimmering()

            VStack(alignment: .leading, spacing: 7) {
                SkeletonLine(width: 120, height: 11)
                SkeletonLine(height: 12)
                SkeletonLine(width: 200, height: 10)
            }
        }
        .padding(.vertical, 6)
        .accessibilityLabel("Loading mail")
    }
}

#Preview {
    List {
        ForEach(MailStore.connected().messages(in: .inbox)) { MessageRow(message: $0) }
        MessageRowSkeleton()
    }
    .listStyle(.plain)
    .environment(MailStore.connected())
}
