import SwiftUI

/// One message in a list. Shared by the inbox and anywhere else messages are
/// listed, so the row looks identical everywhere.
struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(message.isRead ? 0.12 : 0.22))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(message.sender.initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .overlay(alignment: .topLeading) {
                    if !message.isRead {
                        Circle()
                            .fill(.tint)
                            .frame(width: 9, height: 9)
                            .offset(x: -14, y: 15)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.sender.name)
                        .font(.headline)
                        .fontWeight(message.isRead ? .regular : .bold)
                    Spacer(minLength: 8)
                    Text(message.listDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(message.subject)
                    .font(.subheadline)
                    .fontWeight(message.isRead ? .regular : .semibold)
                    .lineLimit(1)

                HStack(alignment: .top, spacing: 4) {
                    Text(message.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !message.sortedTags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.sortedTags) { TagBadge(tag: $0) }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
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

#Preview {
    List {
        ForEach(MailStore.connected().messages(in: .inbox)) { MessageRow(message: $0) }
    }
    .environment(MailStore.connected())
}
