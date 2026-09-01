import SwiftUI
import UIKit

/// The Inbox tab, which is also the home screen.
///
/// The tag pills are pinned directly under the title on the plain background --
/// no card, no hairline, the way Mail's category filters sit. Below them the
/// red "needs your attention" row, then the mail.
///
/// The bar is three controls in two groups, the way the current assistants
/// lay theirs out: one circular button on the left that switches mailbox,
/// and a capsule on the right holding search and compose. Search is a
/// button, not a field: the field only exists once it is asked for, drops
/// in from the top, and is gone again when cancelled.
struct InboxHomeView: View {
    @Environment(MailStore.self) private var mail

    @State private var mailbox: Mailbox = .inbox
    @State private var tag: AITag?
    @State private var isComposing = false
    @State private var isSearching = false
    @State private var query = ""

    private var isBrowsing: Bool { mailbox == .inbox }
    private var messages: [Message] { mail.messages(in: mailbox, tag: tag) }
    private var attention: [Message] { mail.needsAttention(limit: .max) }
    private var availableTags: [AITag] { mail.availableTags(in: mailbox) }

    /// Searching covers every folder, not just the current one -- someone
    /// looking for a message rarely knows or cares where it landed.
    private var searchResults: [Message] {
        guard !query.isEmpty else { return [] }
        return Mailbox.allCases
            .filter { !$0.isSmart }
            .flatMap { mail.messages(in: $0, matching: query) }
            .sorted { $0.date > $1.date }
    }

    private var isSearchActive: Bool { !query.isEmpty }

    var body: some View {
        List {
            if isSearchActive {
                ForEach(searchResults) { message in
                    ZStack {
                        NavigationLink(value: message.id) { EmptyView() }.opacity(0)
                        MessageRow(message: message)
                    }
                    .messageSwipeActions(for: message)
                }
            } else {
                if isBrowsing {
                    summaryCard
                }

                if mail.isLoadingFirstPage {
                    // Scrollable placeholder rows, so connecting a mailbox
                    // shows the shape of a list instead of a blank screen.
                    ForEach(0..<8, id: \.self) { _ in
                        MessageRowSkeleton()
                            .listRowSeparator(.hidden)
                    }
                }

                ForEach(messages) { message in
                    // A ZStack with a zero-opacity link behind the row, rather
                    // than a NavigationLink label: the label form draws a
                    // disclosure chevron on every row, which the reference
                    // list does not have and which cannot be turned off.
                    ZStack {
                        NavigationLink(value: message.id) { EmptyView() }.opacity(0)
                        MessageRow(message: message, threadCount: mail.threadCount(for: message))
                    }
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(Color(uiColor: .separator).opacity(0.45))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 68 }
                    .messageSwipeActions(for: message)
                    .onAppear {
                        // The end of the list is the trigger for the next page.
                        if message.id == messages.last?.id {
                            Task { await mail.loadMore() }
                        }
                    }
                }

                if mail.hasMoreMail && !messages.isEmpty {
                    MessageRowSkeleton()
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await mail.loadMore() } }
                }
            }
        }
        .listStyle(.plain)
        .modifier(SearchWhenAsked(query: $query, isPresented: $isSearching, prompt: "Search all mail"))
        .refreshable { await mail.refresh() }
        .navigationTitle(isBrowsing ? "Maily" : mailbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isBrowsing && !availableTags.isEmpty && !isSearching {
                TagFilterBar(
                    tags: availableTags,
                    count: { mail.unreadCount(of: $0, in: mailbox) },
                    selection: $tag
                )
            }
        }
        .overlay {
            if isSearchActive && searchResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if !isSearchActive {
                // A resumed import (the app was killed partway through) lands
                // here rather than on the connect screen. Only takes the whole
                // screen when there is nothing to show; with mail already on
                // screen it fills in quietly behind instead.
                if mail.importProgress.isRunning && messages.isEmpty {
                    ImportingMailView(progress: mail.importProgress)
                } else if messages.isEmpty && !mail.isLoadingFirstPage {
                    emptyState
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { mailboxButton }
            ToolbarItem(placement: .topBarTrailing) { actionCluster }
        }
        .onChange(of: mailbox) { _, newValue in
            if let tag, mail.count(of: tag, in: newValue) == 0 { self.tag = nil }
        }
        .sheet(isPresented: $isComposing) { ComposeView() }
    }

    // MARK: - The bar

    /// One circle showing where you are; the menu behind it is where you can
    /// go. The bare hamburger it replaces said nothing about either.
    private var mailboxButton: some View {
        Menu {
            Picker("Mailbox", selection: $mailbox) {
                ForEach(Mailbox.allCases) { box in
                    Label(box.title, systemImage: box.systemImage).tag(box)
                }
            }
        } label: {
            Image(systemName: mailbox.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                .contentShape(Circle())
        }
        // Without .plain the toolbar renders its own button background behind
        // this one, and the circle reads as two stacked shapes.
        .buttonStyle(.plain)
        .accessibilityLabel("Mailbox: \(mailbox.title)")
    }

    /// Search and compose together in one capsule, the way ChatGPT and
    /// Perplexity group their bar actions. Compose lives here now instead of
    /// floating over the mail.
    private var actionCluster: some View {
        HStack(spacing: 0) {
            Button {
                isSearching = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Search")

            Button {
                isComposing = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Compose")
        }
        .foregroundStyle(.primary)
        .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        .buttonStyle(PressButtonStyle())
    }

    // MARK: - The one card

    @ViewBuilder
    private var summaryCard: some View {
        Section {
            if let error = mail.connectionError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.footnote)
                    Text(error)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(uiColor: .systemRed))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .systemRed).opacity(0.11))
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))
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
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
            } else if !mail.messages.isEmpty {
                // The reward for clearing it. A warning that simply vanishes
                // gives no sense that anything was achieved -- and an empty
                // gap where a red row used to be reads like a bug.
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color(uiColor: .systemGreen))
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your inbox is clean")
                            .font(.subheadline.weight(.semibold))
                        Text("Nothing is waiting on you right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                .transition(.opacity)
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

/// A search field that exists only while it is wanted.
///
/// `searchable` on its own parks a field under the title permanently, which
/// spends a row of every screen on something reached for occasionally. Here
/// the modifier is applied only while `isPresented` is true: the button adds
/// it (open and focused, dropping in from the top), Cancel removes it, and
/// the query is cleared on the way out so the list is itself again.
struct SearchWhenAsked: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool
    let prompt: String

    func body(content: Content) -> some View {
        Group {
            if isPresented {
                content.searchable(text: $query, isPresented: $isPresented, prompt: prompt)
            } else {
                content
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { query = "" }
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
