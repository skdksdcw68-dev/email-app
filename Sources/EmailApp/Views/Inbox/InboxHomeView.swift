import SwiftUI
import UIKit

/// The Inbox tab, which is also the home screen.
///
/// Two things sit above the mail, sharing one card: the tag chips and the red
/// "needs your attention" row. The chips come first so the filters are the
/// first thing under the title.
///
/// There is no counts strip. Four numbers that restated what the chips already
/// showed was two controls competing over one list.
struct InboxHomeView: View {
    @Environment(MailStore.self) private var mail

    @State private var mailbox: Mailbox = .inbox
    @State private var tag: AITag?
    @State private var isComposing = false
    @State private var isSearching = false

    private var isBrowsing: Bool { mailbox == .inbox }
    private var messages: [Message] { mail.messages(in: mailbox, tag: tag) }
    private var attention: [Message] { mail.needsAttention(limit: .max) }
    private var availableTags: [AITag] { mail.availableTags(in: mailbox) }

    var body: some View {
        List {
            if isBrowsing {
                summaryCard
            }

            Section {
                ForEach(messages) { message in
                    NavigationLink(value: message.id) {
                        MessageRow(message: message)
                    }
                    .messageSwipeActions(for: message)
                }
            } header: {
                Text(tag?.title ?? (isBrowsing ? "Inbox" : mailbox.title))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isBrowsing ? "Maily" : mailbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) { composeButton }
        .overlay {
            if messages.isEmpty { emptyState }
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

    // MARK: - The one card

    @ViewBuilder
    private var summaryCard: some View {
        Section {
            if !availableTags.isEmpty {
                TagFilterBar(
                    tags: availableTags,
                    count: { mail.count(of: $0, in: mailbox) },
                    selection: $tag
                )
                .padding(.vertical, 4)
                // Let the chips run the full width of the card rather than
                // stopping at the standard row inset.
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
            }

            if !attention.isEmpty {
                NavigationLink {
                    AttentionListView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color(uiColor: .systemRed))
                            .frame(width: 26)

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

#Preview {
    NavigationStack {
        InboxHomeView()
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
    }
    .environment(MailStore.connected())
    .environment(UserStore(defaults: .previews, startAt: .finished))
}
