import SwiftUI
import UIKit

/// The Inbox tab, which is also the home screen.
///
/// There is deliberately no separate "Home" tab: the Inbox already holds the
/// main content, and Apple warns against a redundant Home beside it.
///
/// The briefing above the mail is deliberately tiny -- a status line, the
/// counts, and a single row for anything that needs a person. Listing the
/// urgent mail inline just duplicated the inbox underneath it, so that row
/// links out to a dedicated screen instead.
struct InboxHomeView: View {
    @Environment(MailStore.self) private var mail

    @State private var mailbox: Mailbox = .inbox
    @State private var tag: AITag?
    @State private var isComposing = false
    @State private var isSearching = false

    private var isBrowsing: Bool { tag == nil && mailbox == .inbox }
    private var messages: [Message] { mail.messages(in: mailbox, tag: tag) }
    private var availableTags: [AITag] { mail.availableTags(in: mailbox) }
    private var attention: [Message] { mail.needsAttention(limit: .max) }

    var body: some View {
        List {
            if isBrowsing {
                briefing
                attentionRow
                yourDay
            }

            Section {
                ForEach(messages) { message in
                    NavigationLink(value: message.id) {
                        MessageRow(message: message)
                    }
                    .messageSwipeActions(for: message)
                }
            } header: {
                Text(isBrowsing ? "Inbox" : mailbox.title)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isBrowsing ? "Maily" : mailbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !availableTags.isEmpty {
                TagFilterBar(
                    tags: availableTags,
                    count: { mail.count(of: $0, in: mailbox) },
                    selection: $tag
                )
            }
        }
        .overlay(alignment: .bottomTrailing) { composeButton }
        .overlay {
            if messages.isEmpty && !isBrowsing {
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
                    isSearching = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
        }
        .onChange(of: mailbox) { _, newValue in
            if let tag, mail.count(of: tag, in: newValue) == 0 { self.tag = nil }
        }
        .sheet(isPresented: $isComposing) { ComposeView() }
        .sheet(isPresented: $isSearching) { SearchView() }
    }

    // MARK: - Briefing

    private var briefing: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(mail.inboxStatus)
                    .font(.subheadline.weight(.medium))

                CountsStrip(counts: mail.counts)
            }
            .padding(.vertical, 4)
        }
    }

    /// One row, not a list. Tapping it opens the full set -- the point is to
    /// say "something needs you" without reprinting the inbox.
    @ViewBuilder
    private var attentionRow: some View {
        if !attention.isEmpty {
            Section {
                NavigationLink {
                    AttentionListView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color(uiColor: .systemRed))
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(attentionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(attentionDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var attentionTitle: String {
        attention.count == 1
            ? "1 email needs your attention"
            : "\(attention.count) emails need your attention"
    }

    private var attentionDetail: String {
        attention.prefix(2).map(\.sender.name).joined(separator: ", ")
            + (attention.count > 2 ? " and others" : "")
    }

    @ViewBuilder
    private var yourDay: some View {
        let items = mail.dayItems
        if !items.isEmpty {
            Section("Your day") {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Text(item.time)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.tint)
                            .frame(width: 62, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var composeButton: some View {
        Button {
            isComposing = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .accessibilityLabel("Compose")
    }

    @ViewBuilder
    private var emptyState: some View {
        if let tag {
            ContentUnavailableView(
                "No \(tag.title) Mail",
                systemImage: tag.systemImage,
                description: Text("Nothing in \(mailbox.title) is tagged \(tag.title).")
            )
        } else {
            ContentUnavailableView(
                "No Messages",
                systemImage: mailbox.systemImage,
                description: Text("Messages in \(mailbox.title) appear here.")
            )
        }
    }
}

// MARK: - Pieces

private struct CountsStrip: View {
    let counts: InboxCounts

    var body: some View {
        HStack(spacing: 0) {
            item("\(counts.new)", "new", .secondary)
            divider
            item("\(counts.important)", "important", Color(uiColor: .systemOrange))
            divider
            item("\(counts.needsReply)", "replies", Color(uiColor: .systemBlue))
            divider
            item("\(counts.urgent)", "urgent", Color(uiColor: .systemRed))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 1, height: 22)
    }

    private func item(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationStack {
        InboxHomeView()
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
    }
    .environment(MailStore.connected())
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
