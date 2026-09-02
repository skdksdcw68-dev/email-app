import SwiftUI

/// The replies Maily has written and is holding.
///
/// This is the whole of draft mode: Maily decides, writes, and stops. Nothing
/// here has gone anywhere. Reading one and pressing send is the same act as
/// writing it yourself, which is exactly why this is safe to ship before the
/// verification layer exists.
struct AutoReplyQueueView: View {
    @Environment(MailStore.self) private var mail
    @Environment(AutoReplyQueue.self) private var queue
    @Environment(AutoReplyStore.self) private var autoReply

    @State private var open: AutoReplyDecision?

    /// How often it looks again while this screen is open. Somebody testing
    /// this sends themselves an email and watches -- half a minute is short
    /// enough to feel alive and long enough not to hammer Gmail.
    private static let refreshEvery: Duration = .seconds(30)

    var body: some View {
        List {
            statusRow

            if queue.isChecking && queue.waiting.isEmpty {
                Section {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Somebody")
                                .font(.subheadline.weight(.semibold))
                            Text("A subject line goes here")
                                .font(.caption)
                            Text("And the reply Maily wrote for it, two lines long.")
                                .font(.footnote)
                        }
                        .padding(.vertical, 3)
                    }
                    .redacted(reason: .placeholder)
                } header: {
                    Text("Looking")
                }
            } else if queue.waiting.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing waiting",
                        systemImage: "tray",
                        description: Text(emptyExplanation)
                    )
                }

                // What it decided most recently, right here rather than one
                // screen away. "It did nothing" and "it deliberately left
                // these alone, here's why" look identical otherwise, and only
                // one of them is a bug.
                if !queue.log.isEmpty {
                    Section {
                        ForEach(queue.log.prefix(4)) { decision in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Image(systemName: decision.symbol)
                                        .font(.caption2)
                                        .foregroundStyle(decision.outcome == .escalated
                                                         ? Color.orange : Color.secondary)
                                    Text(decision.subject)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                }
                                Text(decision.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Most recently")
                    }
                }
            } else {
                Section {
                    ForEach(queue.waiting) { decision in
                        Button {
                            open = decision
                        } label: {
                            row(decision)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                queue.discard(decision.id)
                            } label: {
                                Label("Bin it", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Waiting for you")
                } footer: {
                    Text("Nothing here has been sent. Open one to read it, edit it, and send it — or bin it.")
                }
            }

            Section {
                NavigationLink { AutoReplyLogView() } label: {
                    Label("What Maily decided", systemImage: "list.bullet.rectangle")
                        .font(.subheadline)
                }
            } footer: {
                Text("Every message Auto-Reply looked at, including the ones it left alone, and why.")
            }
        }
        .navigationTitle("Replies")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .refreshable { await check() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await check() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(queue.isChecking)
            }
        }
        // Looks again while this screen is open, then leaves it alone. A
        // screen somebody is watching should not need a pull to prove the
        // feature is alive.
        .task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: Self.refreshEvery)
            }
        }
        .sheet(item: $open) { decision in
            AutoReplyDraftView(decision: decision)
        }
    }

    private func check() async {
        await mail.runAutoReply(
            config: autoReply.config,
            briefing: autoReply.briefing(),
            queue: queue
        )
    }

    /// The state of the thing, said plainly. Orange when Auto-Reply is not
    /// actually running, because the commonest reason for an empty screen is
    /// that it is switched off and nothing else says so.
    @ViewBuilder
    private var statusRow: some View {
        let config = autoReply.config
        Section {
            HStack(spacing: 11) {
                Image(systemName: statusSymbol)
                    .font(.footnote)
                    .foregroundStyle(config.isRunning ? Color.green : Color.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(config.isRunning ? .primary : Color.orange)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if queue.isChecking { ProgressView() }
            }
            .padding(.vertical, 2)
        }
    }

    private var statusSymbol: String {
        if !autoReply.config.isRunning { return "exclamationmark.triangle.fill" }
        return queue.isChecking ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }

    private var statusTitle: String {
        let config = autoReply.config
        if !config.isSetUp { return "Not set up" }
        if !config.isOn { return "Auto-Reply is off" }
        if !config.knowledgeConfirmed { return "Setup isn't finished" }
        return queue.isChecking ? "Looking at your mail" : "Watching your inbox"
    }

    private var statusDetail: String {
        let config = autoReply.config
        if !config.isSetUp { return "Set it up first and Maily will start watching." }
        if !config.isOn { return "Nothing is being answered. Turn it on from the Auto-Reply screen." }
        if queue.isChecking { return "Checking for anything new." }
        guard let last = queue.lastCheckedAt else { return "Checks every 30 seconds while you're here." }
        return "Last checked \(last.formatted(.relative(presentation: .named))). Checks every 30 seconds while you're here."
    }

    /// Why there is nothing, in the words of the thing that actually decided.
    private var emptyExplanation: String {
        let config = autoReply.config
        if !config.isRunning {
            return "Auto-Reply isn't running, so nothing is being answered yet."
        }
        if queue.log.isEmpty {
            return "Maily hasn't found anything it can answer yet. It only replies to the kinds of mail you allowed, from real people — not newsletters, no-reply addresses, or mail you sent yourself."
        }
        return "Maily has looked at your mail and didn't find anything it could answer on its own. What it decided is below."
    }

    private func row(_ decision: AutoReplyDecision) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(decision.from)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(decision.decidedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(decision.subject)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let reply = decision.reply {
                Text(reply)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            if !decision.withheld.isEmpty {
                Label("\(decision.withheld.count) left for you", systemImage: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// One written reply, before it goes anywhere.
///
/// The reply is editable, because it is theirs. What it leaned on and what it
/// refused to answer sit under it -- that second list is the important one,
/// and burying it would turn a careful assistant into a confident one.
struct AutoReplyDraftView: View {
    let decision: AutoReplyDecision

    @Environment(MailStore.self) private var mail
    @Environment(AutoReplyQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var isSending = false
    @State private var failure: String?

    init(decision: AutoReplyDecision) {
        self.decision = decision
        _text = State(initialValue: decision.reply ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(decision.from).font(.subheadline.weight(.semibold))
                        Text(decision.subject).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Replying to")
                }

                Section {
                    TextField("Reply", text: $text, axis: .vertical)
                        .lineLimit(6...20)
                        .font(.subheadline)
                } header: {
                    Text("Maily wrote")
                } footer: {
                    Text(decision.reason)
                }

                if !decision.evidence.isEmpty {
                    Section {
                        ForEach(decision.evidence, id: \.self) { fact in
                            Label(fact, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("What it used")
                    }
                }

                if !decision.withheld.isEmpty {
                    Section {
                        ForEach(decision.withheld, id: \.self) { item in
                            Label(item, systemImage: "hand.raised.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("What it left for you")
                    } footer: {
                        Text("Maily didn't answer these because they're outside what you approved. Add them yourself before sending, if you want to.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        queue.discard(decision.id)
                        dismiss()
                    } label: {
                        Label("Bin this reply", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await sendIt() }
                    } label: {
                        if isSending { ProgressView() } else { Text("Send").fontWeight(.semibold) }
                    }
                    .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Couldn't send", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func sendIt() async {
        isSending = true
        defer { isSending = false }

        // Whatever is on screen is what goes, edits included. Sending the
        // model's original after somebody changed it would be the worst
        // possible bug in this feature.
        var edited = decision
        edited.reply = text
        do {
            try await mail.sendAutoReply(edited, queue: queue)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Everything Auto-Reply looked at, and what it decided.
///
/// Skips included, and deliberately so. "Why didn't it answer this one?" is
/// the question people actually ask, and a log of successes cannot answer it.
struct AutoReplyLogView: View {
    @Environment(AutoReplyQueue.self) private var queue

    var body: some View {
        List {
            if queue.log.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Once Auto-Reply has looked at some mail, its decisions show up here.")
                )
            } else {
                ForEach(queue.log) { decision in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: decision.symbol)
                                .font(.caption)
                                .foregroundStyle(tint(for: decision.outcome))
                                .frame(width: 18)
                            Text(decision.outcomeTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint(for: decision.outcome))
                            Spacer(minLength: 0)
                            Text(decision.decidedAt.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(decision.subject)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(decision.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("What Maily decided")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }

    private func tint(for outcome: AutoReplyDecision.Outcome) -> Color {
        switch outcome {
        case .drafted: .accentColor
        case .sent: .green
        case .escalated: .orange
        case .skipped: .secondary
        case .failed: .red
        }
    }
}
