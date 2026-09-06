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
    /// Shows the loudest priority tag beside the sender.
    ///
    /// Off in the inbox on purpose -- a badge on most rows of a busy list is
    /// wallpaper, and the filter pills above already carry the tags. On for
    /// the attention list, where every row is there *because* of its tag and
    /// which one is the whole question.
    var showsPriority = false
    /// Two lines of what the AI made of it, rather than one line of the
    /// message's own opening. For lists where the reason a row is present
    /// matters more than what it happens to start with.
    var showsSummary = false

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

    /// What goes under the subject: the AI's reading of it where that is what
    /// the list is for, and otherwise the message's own opening.
    private var secondLine: String {
        if showsSummary, let summary = message.aiSummary { return summary }
        return matchedPreview
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(contact: message.sender, size: 44, isMuted: message.isRead)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsPriority, let priority = message.topPriority {
                        TagBadge(tag: priority)
                    }
                    // One of the person's own categories, if the message is in
                    // any: the first in their order. One, because a row has
                    // one line for the name and the date.
                    if showsPriority,
                       let custom = CategoryStore.shared.custom.first(where: { message.customTags?.contains($0.id) == true }) {
                        CategoryBadge(category: custom)
                    }

                    Text(message.sender.name)
                        .font(Style.rowTitle)
                        .fontWeight(message.isRead ? .medium : .semibold)
                        .lineLimit(1)

                    if threadCount > 1 {
                        Text("\(threadCount)")
                            .font(Style.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                    }

                    Spacer(minLength: 4)

                    Text(message.listDate)
                        .font(Style.rowDetail)
                        .foregroundStyle(.secondary)
                }

                Text(Highlight.mark(message.subject, terms: highlight))
                    .font(Style.rowTitle)
                    .fontWeight(message.isRead ? .regular : .bold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Highlight.mark(secondLine, terms: highlight))
                        .font(Style.rowPreview)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsSummary ? 2 : 1)

                    Spacer(minLength: 0)

                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(Style.caption)
                            .foregroundStyle(Color.flagged)
                    }
                    if message.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(Style.caption)
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

    /// A swipe action cannot open a menu, so the choice of when arrives as a
    /// sheet the moment the swipe finishes.
    @State private var isPickingWhen = false

    private var isAsleep: Bool { SnoozeStore.isAsleep(message.remoteID) }

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

                // Drafts are not a thing you put off until Tuesday; they are
                // a thing you finish. No snooze on them.
                if message.mailbox != .drafts, message.remoteID != nil {
                    Button {
                        if isAsleep {
                            SnoozeStore.wake(message.remoteID ?? "")
                            store.notePreferencesChanged()
                        } else {
                            isPickingWhen = true
                        }
                    } label: {
                        Label(isAsleep ? "Wake" : "Snooze", systemImage: isAsleep ? "bell" : "clock")
                    }
                    .tint(.indigo)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    if message.mailbox == .drafts {
                        Task { await store.discardDraft(message.id) }
                    } else {
                        store.delete(message.id)
                    }
                } label: {
                    Label(message.mailbox == .drafts ? "Discard" : "Delete", systemImage: "trash")
                }

                Button {
                    store.toggleFlag(message.id)
                } label: {
                    Label("Flag", systemImage: "flag")
                }
                .tint(.orange)
            }
            .sheet(isPresented: $isPickingWhen) {
                SnoozeSheet(subject: message.subject) { snooze(until: $0) }
            }
    }

    private func snooze(until date: Date) {
        guard let remoteID = message.remoteID else { return }
        SnoozeStore.snooze(remoteID, until: date)
        // Snoozing lives outside the mailbox, so nothing about `messages`
        // changed. This is what tells the lists to look again.
        store.notePreferencesChanged()
        Analytics.record(.messageSnoozed)
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
