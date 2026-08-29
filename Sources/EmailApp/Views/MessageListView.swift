import SwiftUI

struct MessageListView: View {
    @Environment(MailStore.self) private var store

    @State private var mailbox: Mailbox = .inbox
    @State private var tag: AITag?
    @State private var query = ""
    @State private var isComposing = false

    private var messages: [Message] {
        store.messages(in: mailbox, tag: tag, matching: query)
    }

    private var availableTags: [AITag] {
        store.availableTags(in: mailbox)
    }

    var body: some View {
        List {
            ForEach(messages) { message in
                NavigationLink(value: message.id) {
                    MessageRow(message: message)
                }
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
        .listStyle(.plain)
        .navigationTitle(mailbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search mail")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !availableTags.isEmpty {
                TagFilterBar(
                    tags: availableTags,
                    count: { store.count(of: $0, in: mailbox) },
                    selection: $tag
                )
            }
        }
        .overlay {
            if messages.isEmpty {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Mailbox", selection: $mailbox) {
                        ForEach(Mailbox.allCases) { box in
                            Label(box.title, systemImage: box.systemImage).tag(box)
                        }
                    }
                } label: {
                    Label("Mailboxes", systemImage: "line.3.horizontal")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isComposing = true
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
            }
        }
        // A tag that exists in one mailbox may not exist in the next.
        .onChange(of: mailbox) { _, newValue in
            if let tag, store.count(of: tag, in: newValue) == 0 {
                self.tag = nil
            }
        }
        .sheet(isPresented: $isComposing) {
            ComposeView()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let tag {
            ContentUnavailableView(
                "No \(tag.title) Mail",
                systemImage: tag.systemImage,
                description: Text("Nothing in \(mailbox.title) is tagged \(tag.title).")
            )
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                "No Messages",
                systemImage: mailbox.systemImage,
                description: Text("Messages in \(mailbox.title) appear here.")
            )
        }
    }
}

private struct MessageRow: View {
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

#Preview {
    NavigationStack { MessageListView() }
        .environment(MailStore.connected())
}
