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

            // Everything it has written before, openable. A reply it sent
            // last Tuesday is the thing somebody wants to look at when they
            // are deciding whether to trust this, and it should not take a
            // search of their Sent folder to find it.
            let history = queue.log.filter { $0.reply != nil || $0.outcome == .sent }
            if !history.isEmpty {
                Section {
                    ForEach(history.prefix(20)) { decision in
                        NavigationLink {
                            AutoReplyDetailView(decision: decision)
                        } label: {
                            historyRow(decision)
                        }
                    }
                } header: {
                    Text("Already written")
                } footer: {
                    Text("Tap any of these to read what Maily said.")
                }
            }

            Section {
                NavigationLink { AutoReplyLogView() } label: {
                    Label("Everything it looked at", systemImage: "list.bullet.rectangle")
                        .font(.subheadline)
                }
            } footer: {
                Text("Including the mail it left alone, and why.")
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
            return "Maily is watching for new mail. It only answers what arrives from now on, in the kinds you allowed, from real people — not newsletters, no-reply addresses, or mail you sent yourself."
        }
        return "Maily has looked at what came in and had nothing it could answer on its own."
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: decision.symbol)
                                .font(.caption)
                                .foregroundStyle(tint(for: decision.outcome))
                                .frame(width: 18)
                            Text(decision.outcomeTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint(for: decision.outcome))
                            // How sure it was, where it got far enough to be
                            // sure of anything. This is the number to watch
                            // before trusting it to send.
                            if let confidence = decision.verification?.confidence, confidence > 0 {
                                Text("\(Int(confidence * 100))%")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
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

                        // What the device check caught, which is a different
                        // thing from what the model chose not to answer, and
                        // the more interesting of the two.
                        ForEach(decision.verification?.problems ?? [], id: \.self) { problem in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(problem)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
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

extension AutoReplyQueueView {

    /// A reply Maily has already written, sent or binned.
    func historyRow(_ decision: AutoReplyDecision) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: decision.symbol)
                    .font(.caption2)
                    .foregroundStyle(historyTint(decision.outcome))
                    .frame(width: 16)
                Text(decision.outcomeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(historyTint(decision.outcome))
                Spacer(minLength: 0)
                Text(decision.decidedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(decision.from)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(decision.subject)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    func historyTint(_ outcome: AutoReplyDecision.Outcome) -> Color {
        switch outcome {
        case .sent: .green
        case .drafted: .accentColor
        case .escalated: .orange
        case .skipped: .secondary
        case .failed: .red
        }
    }
}

/// One reply Maily wrote, read back afterwards.
///
/// Read-only on purpose. A reply that has gone cannot be unsent and a reply
/// that was binned is not coming back, so offering an editor here would be
/// offering something the app cannot honour. What it can do is show exactly
/// what was said, what it leaned on, and what it refused -- which is the
/// whole of what somebody deciding whether to trust this needs.
struct AutoReplyDetailView: View {
    let decision: AutoReplyDecision

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(decision.from).font(.subheadline.weight(.semibold))
                    Text(decision.subject).font(.caption).foregroundStyle(.secondary)
                    Text(decision.decidedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text(decision.outcomeTitle)
            } footer: {
                Text(decision.reason)
            }

            if let reply = decision.reply, !reply.isEmpty {
                Section {
                    Text(reply)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } header: {
                    Text("What Maily wrote")
                }
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
                    Text("What it left alone")
                }
            }

            if let verification = decision.verification, verification.confidence > 0 {
                Section {
                    LabeledContent("How sure it was", value: "\(Int(verification.confidence * 100))%")
                    ForEach(verification.problems, id: \.self) { problem in
                        Label(problem, systemImage: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("The check")
                }
            }
        }
        .navigationTitle("Reply")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }
}
