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
                    // The same card the assistant uses in chat, because it is
                    // the same thing: an email Maily wrote, waiting on a
                    // decision. Two different cards for one idea would be the
                    // app forgetting what it is.
                    ForEach(queue.waiting) { decision in
                        AutoReplyCard(decision: decision)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Waiting for you")
                } footer: {
                    Text("Nothing here has been sent. Edit opens the full editor, where you can ask Maily to change it.")
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
