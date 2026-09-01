import SwiftUI
import UIKit

/// The Inbox tab, which is also the home screen.
///
/// The tag pills are pinned directly under the title on the plain background --
/// no card, no hairline, the way Mail's category filters sit. Below them the
/// red "needs your attention" row, then the mail.
///
/// The bar is three controls in two groups: a mailbox switcher on the left,
/// search and compose together on the right. They are plain toolbar items
/// on purpose -- the system draws the container, so they look exactly like
/// every other bar in the app. Search is a button, not a field: the field
/// only exists once it is asked for, drops in from the top, and is gone
/// again when cancelled.
struct InboxHomeView: View {
    @Environment(MailStore.self) private var mail

    @State private var mailbox: Mailbox = .inbox
    @State private var tag: AITag?
    @State private var isComposing = false
    @State private var isSearching = false
    @State private var query = ""
    @State private var searchMode: MailStore.SearchMode = .mail
    /// Held until the notice is answered, so agreeing runs the search they
    /// already asked for rather than making them type it again.
    @State private var pendingAISearch: String?

    private var isBrowsing: Bool { mailbox == .inbox }

    /// Searching covers every folder, not just the current one -- someone
    /// looking for a message rarely knows or cares where it landed.
    private var searchResults: [Message] {
        guard !query.isEmpty else { return [] }

        // What is already on the phone, matched as they type. Instant, and
        // covers the three months most searches are actually about.
        let local = Mailbox.allCases
            .filter { !$0.isSmart }
            .flatMap { mail.messages(in: $0, matching: query) }

        // What Gmail found, which reaches the whole account. Merged rather
        // than replacing: a local match Gmail's index has not caught up with
        // should not vanish the moment the request returns.
        var seen = Set<Message.ID>()
        return (mail.searchResults + local)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }
    }

    /// Words to mark in the results: whatever the AI decided to look for,
    /// or failing that, what was typed.
    private var highlightTerms: [String] {
        mail.searchTerms.isEmpty ? Highlight.terms(in: query) : mail.searchTerms
    }

    private var isSearchActive: Bool { !query.isEmpty }

    var body: some View {
        // Each of these sorts the mailbox. Once per render, not once per
        // row: computing the list again inside every row's onAppear was a
        // sort of two thousand messages on every scroll step.
        let messages = mail.messages(in: mailbox, tag: tag)
        let lastID = messages.last?.id
        let attention = mail.needsAttention(limit: .max)
        let counts = mail.tagCounts(in: mailbox)
        let availableTags = AITag.allCases.filter { (counts.total[$0] ?? 0) > 0 }

        return List {
            if isSearchActive {
                searchHeader

                ForEach(searchResults) { message in
                    ZStack {
                        NavigationLink(value: message.id) { EmptyView() }.opacity(0)
                        MessageRow(message: message, highlight: highlightTerms)
                    }
                    .messageSwipeActions(for: message)
                }

                if searchResults.isEmpty && !mail.isSearchingRemotely {
                    Text(searchMode == .ai
                         ? "Nothing matched. Try describing it differently."
                         : "Nothing here matches. Press search to look through all your mail.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            } else {
                if isBrowsing {
                    summaryCard(attention: attention)
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
                        if message.id == lastID {
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
        .modifier(SearchWhenAsked(query: $query, isPresented: $isSearching, prompt: searchPrompt))
        // Typing filters what is on the phone; pressing search asks Gmail.
        // Running a network search on every keystroke would be a request per
        // letter, and an AI call per letter.
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: isSearching) { _, presented in
            if !presented {
                mail.clearSearch()
                searchMode = .mail
            }
        }
        .alert("AI search uses more of your allowance", isPresented: aiNoticeBinding) {
            Button("Not now", role: .cancel) {
                pendingAISearch = nil
                searchMode = .mail
            }
            Button("Search") {
                AppSettings.hasSeenAISearchNotice = true
                if let text = pendingAISearch {
                    pendingAISearch = nil
                    Task { await mail.search(text, mode: .ai) }
                }
            }
        } message: {
            Text("Maily reads what you typed and writes a proper mail search from it, so you can look for \"that invoice from the landlord last spring\". It costs a request each time. Plain search is free and unlimited.")
        }
        .refreshable { await mail.refresh() }
        .navigationTitle(isBrowsing ? "Maily" : mailbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isBrowsing && !availableTags.isEmpty && !isSearching {
                TagFilterBar(
                    tags: availableTags,
                    count: { counts.unread[$0] ?? 0 },
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
            ToolbarItem(placement: .topBarLeading) {
                // The glyph is where you are; the menu behind it is where
                // you can go. The bare hamburger said nothing about either.
                Menu {
                    Picker("Mailbox", selection: $mailbox) {
                        ForEach(Mailbox.allCases) { box in
                            Label(box.title, systemImage: box.systemImage).tag(box)
                        }
                    }
                } label: {
                    Image(systemName: mailbox.systemImage)
                }
                .accessibilityLabel("Mailbox: \(mailbox.title)")
            }

            // One group, so the system draws them in one capsule -- the same
            // capsule the People tab's search and menu share.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isSearching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")

                Button {
                    isComposing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Compose")
            }
        }
        .onChange(of: mailbox) { _, newValue in
            if let tag, mail.count(of: tag, in: newValue) == 0 { self.tag = nil }
        }
        .sheet(isPresented: $isComposing) { ComposeView() }
    }

    // MARK: - The one card

    @ViewBuilder
    private func summaryCard(attention: [Message]) -> some View {
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
                            Text(attention.count == 1
                                 ? "1 email needs your attention"
                                 : "\(attention.count) emails need your attention")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(attention.prefix(2).map(\.sender.name).joined(separator: ", ")
                                 + (attention.count > 2 ? " and others" : ""))
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

// MARK: - Search

extension InboxHomeView {

    fileprivate var searchPrompt: String {
        searchMode == .ai ? "Describe what you remember" : "Search all mail"
    }

    /// The alert is open when a search is waiting on it. Bound rather than
    /// flagged, so dismissing by any route lands in one place.
    fileprivate var aiNoticeBinding: Binding<Bool> {
        Binding(
            get: { pendingAISearch != nil },
            set: { if !$0 { pendingAISearch = nil } }
        )
    }

    fileprivate func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        Analytics.record(.searchUsed, [
            "mode": .string(searchMode.rawValue),
            "length": .int(text.count),
        ])

        guard searchMode == .ai else {
            Task { await mail.search(text, mode: .mail) }
            return
        }
        // Said once, the first time it would cost something.
        guard AppSettings.hasSeenAISearchNotice else {
            pendingAISearch = text
            return
        }
        Task { await mail.search(text, mode: .ai) }
    }

    /// The mode picker, and whatever the last search has to say for itself.
    @ViewBuilder
    fileprivate var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Text, not Label: a segmented control renders one or the other
            // unpredictably, and a picker whose segments show only an icon on
            // some builds is not a picker.
            Picker("How to search", selection: $searchMode) {
                ForEach(MailStore.SearchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if mail.isSearchingRemotely {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(searchMode == .ai ? "Working out what to look for…" : "Searching all your mail…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let explanation = mail.searchExplanation, !explanation.isEmpty {
                Label(explanation, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if searchMode == .ai {
                Text("Describe it however you remember it, then press search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = mail.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
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
