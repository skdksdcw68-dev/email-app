import SwiftUI
import UIKit

/// The Inbox tab, which is also the home screen.
///
/// Everything above the mail shares one card: the red "needs your attention"
/// row, the four counts, and the tag chips. No hairline between the chips and
/// the rest, and no separate pinned bar -- that separation was what made the
/// chips look bolted on.
///
/// The counts and the chips drive the *same* filter, so selecting Urgent in
/// either place highlights both.
struct InboxHomeView: View {
    @Environment(MailStore.self) private var mail

    @State private var mailbox: Mailbox = .inbox
    @State private var filter: InboxFilter?
    @State private var isComposing = false
    @State private var isSearching = false

    private var isBrowsing: Bool { mailbox == .inbox }

    private var messages: [Message] {
        mail.messages(in: mailbox, tag: filter?.tag, unreadOnly: filter == .unread)
    }

    private var attention: [Message] { mail.needsAttention(limit: .max) }
    private var availableTags: [AITag] { mail.availableTags(in: mailbox) }

    /// Chips speak in tags; the shared filter also has an unread case.
    private var tagSelection: Binding<AITag?> {
        Binding(
            get: { if case .tag(let tag) = filter { tag } else { nil } },
            set: { newValue in
                withAnimation(.snappy(duration: 0.2)) {
                    filter = newValue.map { InboxFilter.tag($0) }
                }
            }
        )
    }

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
                Text(filter?.title ?? (isBrowsing ? "Inbox" : mailbox.title))
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
        .onChange(of: mailbox) { _, _ in filter = nil }
        .sheet(isPresented: $isComposing) { ComposeView() }
        .sheet(isPresented: $isSearching) { SearchView() }
    }

    // MARK: - The one card

    @ViewBuilder
    private var summaryCard: some View {
        Section {
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

            VStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(CountOption.all) { option in
                        StatColumn(
                            value: count(for: option.filter),
                            label: option.label,
                            tint: option.tint,
                            isSelected: filter == option.filter
                        ) {
                            withAnimation(.snappy(duration: 0.2)) {
                                filter = filter == option.filter ? nil : option.filter
                            }
                        }
                    }
                }

                if !availableTags.isEmpty {
                    TagFilterBar(
                        tags: availableTags,
                        count: { mail.count(of: $0, in: mailbox) },
                        selection: tagSelection
                    )
                }
            }
            .padding(.vertical, 4)
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

    private func count(for option: InboxFilter) -> Int {
        mail.messages(in: mailbox, tag: option.tag, unreadOnly: option == .unread).count
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
        if let filter {
            ContentUnavailableView(
                "Nothing \(filter.title)",
                systemImage: filter.symbol,
                description: Text("No mail in \(mailbox.title) matches this filter.")
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

// MARK: - Filter

/// One filter, driven by both the counts and the chips.
enum InboxFilter: Hashable {
    case unread
    case tag(AITag)

    var tag: AITag? {
        if case .tag(let tag) = self { tag } else { nil }
    }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .tag(let tag): tag.title
        }
    }

    var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .tag(let tag): tag.systemImage
        }
    }
}

/// The four columns in the counts row.
private struct CountOption: Identifiable {
    let id: String
    let label: String
    let filter: InboxFilter
    let tint: Color

    static let all: [CountOption] = [
        .init(id: "new", label: "New", filter: .unread, tint: Color(uiColor: .label)),
        .init(id: "important", label: "Important", filter: .tag(.important), tint: Color(uiColor: .systemOrange)),
        .init(id: "replies", label: "Replies", filter: .tag(.needsReply), tint: Color(uiColor: .systemBlue)),
        .init(id: "urgent", label: "Urgent", filter: .tag(.urgent), tint: Color(uiColor: .systemRed)),
    ]
}

/// No separator between columns on purpose -- the point was to stop the summary
/// looking like cells crammed against hairlines.
private struct StatColumn: View {
    let value: Int
    let label: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(value)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(value == 0 && !isSelected ? Color.secondary : tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? tint.opacity(0.14) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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
