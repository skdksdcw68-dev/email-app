import SwiftUI

/// One message in a list. Shared by the inbox and anywhere else messages are
/// listed, so the row looks identical everywhere.
///
/// Three lines: who, what, and the opening of it. The reference app's list
/// reads calmly because that is all it shows -- no chevron, no stack of
/// chips, no card around each row. The one badge here is the loudest thing
/// the AI decided; the rest of the tags live on the filter pills above, where
/// they can be acted on rather than just read.
struct MessageRow: View {
    let message: Message
    /// How many messages are in this conversation. 1 hides the count.
    var threadCount: Int = 1

    /// At most one. Priority wins over kind: "Very Urgent" earns the space
    /// more than "Newsletter" does.
    private var badge: AITag? {
        message.topPriority ?? message.sortedTags.first { AITag.kinds.contains($0) }
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

                Text(message.subject)
                    .font(.subheadline)
                    .fontWeight(message.isRead ? .regular : .bold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.preview)
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

                if let badge {
                    TagBadge(tag: badge)
                        .padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .leading) {
            // Unread marker, hard against the leading edge so it reads as a
            // margin mark rather than as part of the avatar.
            if !message.isRead {
                Circle()
                    .fill(.tint)
                    .frame(width: 8, height: 8)
                    .offset(x: -12)
            }
        }
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
