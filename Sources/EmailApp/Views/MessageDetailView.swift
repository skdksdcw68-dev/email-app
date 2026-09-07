import SwiftUI
import UIKit

struct MessageDetailView: View {
    let messageID: Message.ID

    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isReplying = false
    /// The same sheet, addressed to everybody rather than to the sender.
    @State private var isReplyingAll = false
    /// Passing it on, which is not the same as answering it -- and used to
    /// be the same flag, so Forward opened a reply to the sender.
    @State private var isForwarding = false
    /// A link that was tapped and has not been opened yet.
    @State private var pendingLink: URL?
    /// Which messages in the conversation are showing their body. The one
    /// that was opened, to start with; the rest are a header until asked for.
    @State private var expanded: Set<Message.ID> = []

    private var message: Message? { store.message(messageID) }

    /// The model is still working on this one. Keyed to this message rather
    /// than to the background pass, because opening a message now summarises
    /// it on demand -- every email that gets read gets a summary, including
    /// the bulk mail the background pass deliberately skips.
    private var isSummaryPending: Bool {
        guard let message else { return false }
        return message.aiSummary == nil && store.summarizing.contains(messageID)
    }

    var body: some View {
        Group {
            if let message {
                content(for: message)
            } else {
                ContentUnavailableView("Message Deleted", systemImage: "trash")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // The reading view is a full-screen context. Leaving the tab bar under
        // an action bar stacks two chrome layers and eats the message.
        .hidesTabBar()
        .safeAreaInset(edge: .bottom) {
            if message != nil { replyBar }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let message { optionsMenu(for: message) }
            }
        }
        .onAppear {
            store.markRead(messageID)
            Task { await store.summarize(messageID) }
            // The one they tapped. Older messages in the conversation stay
            // shut: a thread that opens as eleven full emails is a thread
            // nobody can find their place in.
            expanded.insert(messageID)
        }
        .confirmationDialog(
            pendingLink?.host.map { "Open \($0)?" } ?? "Open this link?",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible
        ) {
            if let url = pendingLink {
                Button("Open") { UIApplication.shared.open(url) }
                Button("Copy link") { UIPasteboard.general.string = url.absoluteString }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            // The whole address, not the host alone: the deception is often
            // in the path -- paypal.com.verify-account.top/login.
            if let url = pendingLink { Text(url.absoluteString) }
        }
        .sheet(isPresented: $isReplying) {
            if let message {
                ComposeView(replyingTo: message).closesOnlyOnPurpose()
            }
        }
        .sheet(isPresented: $isReplyingAll) {
            if let message {
                ComposeView(replyingTo: message, replyAll: true).closesOnlyOnPurpose()
            }
        }
        .sheet(isPresented: $isForwarding) {
            if let message {
                ComposeView(forwarding: message).closesOnlyOnPurpose()
            }
        }
    }

    // MARK: - Chrome

    /// Everything that is not "reply" lives behind the ellipsis. Loose archive
    /// and forward icons took up the bar without earning it -- they are one tap
    /// away here and the bar is now a single clear action.
    private func optionsMenu(for message: Message) -> some View {
        Menu {
            Button {
                store.toggleFlag(message.id)
            } label: {
                Label(message.isFlagged ? "Remove star" : "Star",
                      systemImage: message.isFlagged ? "star.slash" : "star")
            }

            Button {
                store.markRead(message.id, false)
                dismiss()
            } label: {
                Label("Mark as unread", systemImage: "envelope.badge")
            }

            // Forward moved to the bar beside Reply, with Reply all. Leaving
            // a copy here would be two routes to one sheet.

            Divider()

            Button {
                store.move(message.id, to: .archive)
                dismiss()
            } label: {
                Label("Archive", systemImage: "archivebox")
            }

            Button(role: .destructive) {
                store.delete(message.id)
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            // A plain glyph. The bar draws its own container around toolbar
            // items; a hand-drawn circle inside that read as two shapes in
            // two colours next to the system's back button.
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More options")
    }

    /// One action, and the two next to it behind a second button.
    ///
    /// Reply is what somebody came here to do and stays a full-width target.
    /// Reply all and Forward earn a place in the bar -- they were a menu away
    /// at the top right, which is not where anybody looks after reading a
    /// message -- without competing with it.
    ///
    /// Dictation lives on the reply screen, not here: opening a message
    /// should not arm a microphone.
    private var replyBar: some View {
        HStack(spacing: 10) {
            Button {
                isReplying = true
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)

            Menu {
                if canReplyAll {
                    Button {
                        isReplyingAll = true
                    } label: {
                        Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                    }
                }
                Button {
                    isForwarding = true
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.forward")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
            }
            .accessibilityLabel("More ways to answer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Only when there is somebody else on it. "Reply all" on a message sent
    /// to one person is the same button twice.
    private var canReplyAll: Bool {
        guard let message else { return false }
        return !ComposeView.everyoneElse(on: message, mine: store.account?.address).isEmpty
    }

    // MARK: - Content

    /// The conversation, oldest at the top.
    ///
    /// 🔴 This screen used to show exactly one message. The list has always
    /// collapsed a conversation into a single row -- four "Security alert"
    /// mails are one row -- so opening it showed the newest and silently hid
    /// the other three, which were already imported and sitting in the store.
    /// A reply that quoted something you could not find in the app was the
    /// normal experience of a thread.
    private func content(for message: Message) -> some View {
        let thread = store.thread(of: message.id)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.subject)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    if thread.count > 1 {
                        Text("\(thread.count) messages")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !message.sortedTags.isEmpty || !(message.customTags ?? []).isEmpty {
                    // Under the names the person gave them, and with any of
                    // their own categories after the built-ins.
                    let categories = CategoryStore.shared
                    let custom = categories.custom.filter { message.customTags?.contains($0.id) == true }
                    HStack(spacing: 6) {
                        ForEach(message.sortedTags) { CategoryBadge(category: categories.category(for: $0)) }
                        ForEach(custom) { CategoryBadge(category: $0) }
                    }
                }

                if isSummaryPending {
                    summarySkeleton
                } else if let summary = message.aiSummary {
                    AISummaryCard(summary: summary)
                }

                Divider()

                // Oldest first, newest at the bottom -- the order it
                // happened in, and Gmail's.
                ForEach(thread) { entry in
                    ThreadMessageView(
                        message: entry,
                        isExpanded: expanded.contains(entry.id),
                        isLast: entry.id == thread.last?.id,
                        onToggle: { toggle(entry.id) },
                        onLink: { pendingLink = $0 }
                    )
                }
            }
            .padding()
        }
    }

    /// Opening one and closing another are the same tap.
    private func toggle(_ id: Message.ID) {
        withAnimation(.snappy(duration: 0.22)) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
                // Reading an older message in a thread is reading it.
                store.markRead(id)
            }
        }
    }

    private var summarySkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            SkeletonLine()
            SkeletonLine(width: 180)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
        }
    }
}

private struct AISummaryCard: View {
    let summary: String
    @State private var justArrived = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AI Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)

            SelectableText(summary, font: .preferredFont(forTextStyle: .subheadline))
                .frame(maxWidth: .infinity, alignment: .leading)
                // A single pass over the text as it lands, so a summary that
                // appears mid-read announces itself instead of silently
                // replacing a skeleton.
                .shimmering(justArrived)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                justArrived = false
            }
        }
    }
}

#Preview {
    let store = MailStore.connected()
    return NavigationStack {
        MessageDetailView(messageID: store.messages(in: .inbox)[0].id)
    }
    .environment(store)
    .environment(UserStore(defaults: .previews, startAt: .finished))
    .environment(AttachmentStore())
}
