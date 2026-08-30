import SwiftUI
import UIKit

/// The Inbox tab, which is also the home screen.
///
/// Everything above the mail lives in one card -- the status line and four
/// counts, with no dividers and no separate filter bar. The counts are the
/// filter: tapping Urgent shows the urgent mail. That replaced a cramped chip
/// strip sitting under a hairline, and it means the numbers do real work
/// instead of decorating the top of the screen.
struct InboxHomeView: View {
    @Environment(MailStore.self) private var mail

    @State private var mailbox: Mailbox = .inbox
    @State private var filter: InboxFilter?
    @State private var isComposing = false
    @State private var isSearching = false

    private var isBrowsing: Bool { mailbox == .inbox }

    private var messages: [Message] {
        mail.messages(
            in: mailbox,
            tag: filter?.tag,
            unreadOnly: filter == .unread
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

    private var summaryCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text(mail.inboxStatus)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(InboxFilter.allCases) { option in
                        StatColumn(
                            value: count(for: option),
                            label: option.label,
                            tint: option.tint,
                            isSelected: filter == option
                        ) {
                            withAnimation(.snappy(duration: 0.2)) {
                                filter = filter == option ? nil : option
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
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
                "Nothing \(filter.label)",
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

// MARK: - Filters

/// The four counts double as the inbox's filters.
enum InboxFilter: String, CaseIterable, Identifiable {
    case unread, important, replies, urgent

    var id: Self { self }

    var label: String {
        switch self {
        case .unread: "New"
        case .important: "Important"
        case .replies: "Replies"
        case .urgent: "Urgent"
        }
    }

    var tag: AITag? {
        switch self {
        case .unread: nil
        case .important: .important
        case .replies: .needsReply
        case .urgent: .urgent
        }
    }

    var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .important: "exclamationmark"
        case .replies: "arrowshape.turn.up.left.fill"
        case .urgent: "exclamationmark.3"
        }
    }

    var tint: Color {
        switch self {
        case .unread: Color(uiColor: .label)
        case .important: Color(uiColor: .systemOrange)
        case .replies: Color(uiColor: .systemBlue)
        case .urgent: Color(uiColor: .systemRed)
        }
    }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .important: "Important"
        case .replies: "Needs reply"
        case .urgent: "Urgent"
        }
    }
}

/// No separator between columns on purpose -- the whole point was to stop the
/// summary looking like cells crammed against hairlines.
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
