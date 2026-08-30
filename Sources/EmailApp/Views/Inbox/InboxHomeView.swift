import SwiftUI
import UIKit

/// The Inbox tab, which is also the home screen.
///
/// There is deliberately no separate "Home" tab: Apple's own guidance warns
/// against a Home tab when another tab already holds the main content. Opening
/// Maily should immediately answer "what needs me?", so the briefing sits above
/// the mail rather than beside it.
///
/// The briefing hides while searching or filtering -- at that point the user has
/// asked a specific question and wants results, not a summary.
struct InboxHomeView: View {
    @Environment(MailStore.self) private var mail
    @Environment(UserStore.self) private var user

    @State private var mailbox: Mailbox = .inbox
    @State private var tag: AITag?
    @State private var query = ""
    @State private var isComposing = false

    private var isBrowsing: Bool { query.isEmpty && tag == nil && mailbox == .inbox }
    private var messages: [Message] { mail.messages(in: mailbox, tag: tag, matching: query) }
    private var availableTags: [AITag] { mail.availableTags(in: mailbox) }

    var body: some View {
        List {
            if isBrowsing {
                briefing
                needsAttention
                recommendations
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
        .searchable(text: $query, prompt: "Search mail")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !availableTags.isEmpty {
                TagFilterBar(
                    tags: availableTags,
                    count: { mail.count(of: $0, in: mailbox) },
                    selection: $tag
                )
            }
        }
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
                    isComposing = true
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
            }
        }
        .onChange(of: mailbox) { _, newValue in
            if let tag, mail.count(of: tag, in: newValue) == 0 { self.tag = nil }
        }
        .sheet(isPresented: $isComposing) { ComposeView() }
    }

    // MARK: - Briefing

    private var briefing: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(greeting)
                    .font(.title2.bold())

                Text(mail.inboxStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                CountsStrip(counts: mail.counts)
                    .padding(.top, 4)
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 12, trailing: 4))
        }
    }

    private var greeting: String {
        guard let name = user.account?.displayName.split(separator: " ").first else {
            return Date.greeting
        }
        return "\(Date.greeting), \(name)"
    }

    @ViewBuilder
    private var needsAttention: some View {
        let items = mail.needsAttention()
        if !items.isEmpty {
            Section("Needs your attention") {
                ForEach(items) { message in
                    NavigationLink(value: message.id) {
                        AttentionCard(message: message)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recommendations: some View {
        let items = mail.recommendations
        if !items.isEmpty {
            Section("Maily recommends") {
                ForEach(items) { recommendation in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { tag = recommendation.tag }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: recommendation.symbol)
                                .font(.title3)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.tint)
                                .frame(width: 28)

                            Text(recommendation.text)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(recommendation.actionLabel)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
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

private struct AttentionCard: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let priority = message.topPriority {
                    TagBadge(tag: priority)
                }
                Text("\(message.sender.name) · \(message.subject)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Text(message.aiSummary ?? message.preview)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
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
