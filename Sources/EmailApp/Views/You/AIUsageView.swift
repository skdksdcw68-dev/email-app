import SwiftUI

/// What the AI has cost, and how much is left.
///
/// Built to the shape Abel asked for: a bar for the period you are in, then
/// what you can do about it. The differences from Claude's version are his
/// too, and they are not cosmetic --
///
/// - **No session bar and no weekly bar.** Nothing here resets on a timer. A
///   month's allowance runs down once and is gone; it comes back when the
///   plan renews and not before.
/// - **So no "resets in 32 min".** The only date worth printing is renewal.
/// - **Running out is not a wait.** It is buy credits, or move up a plan.
///
/// ⚠️ The spend is real -- priced on the server from OpenAI's own token
/// counts. The *plan* is not: there is nothing to buy yet, so everybody is on
/// Free and the buttons say so rather than opening a paywall onto nothing.
struct AIUsageView: View {
    @Environment(MailStore.self) private var mail

    @State private var usage = UsageStore()

    private var plan: Plan { .current }
    private var spent: Double { usage.spend?.thisMonth ?? 0 }
    private var allowance: Double { plan.monthlyAllowanceUSD }
    private var fraction: Double { allowance > 0 ? min(1, spent / allowance) : 0 }


    var body: some View {
        // Three sections: where you are, what to do about it, and one way in
        // to the detail.
        //
        // It had five -- the bar, the credits, a row per feature, a link to
        // Preferences and a destructive reset button. Most of a screen about
        // one number was other things, and the number is the point.
        List {
            periodSection
            creditsSection
            detailSection
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .refreshable { await usage.refresh() }
        .task { await usage.refresh() }
    }

    // MARK: - This period

    private var periodSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(plan.title)
                        .font(Style.rowTitleStrong)
                    Spacer(minLength: 8)
                    Text("\(Int(fraction * 100))% used")
                        .font(Style.rowTitle)
                        .foregroundStyle(fraction >= 1 ? Color.urgent : .secondary)
                        .monospacedDigit()
                }

                ProgressView(value: fraction)
                    .tint(fraction >= 1 ? Color.urgent : (fraction > 0.8 ? Color.warning : Color.accentColor))

                HStack(alignment: .firstTextBaseline) {
                    // The money, plainly. Four decimal places because a
                    // single classification costs a fraction of a cent, and
                    // rounding it to £0.00 would make the screen look broken
                    // for anybody who has not used it much.
                    Text("\(Self.money(spent)) of \(Self.money(allowance))")
                        .font(Style.rowDetail)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(Self.renewal)
                        .font(Style.rowDetail)
                        .foregroundStyle(.tertiary)
                }

                if usage.isLoading {
                    ProgressView().controlSize(.small)
                } else if let failure = usage.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(Style.rowDetail)
                        .foregroundStyle(Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        } header: {
            Text("This month")
        } footer: {
            // ⚠️ Said outright, because it is the part that differs from every
            // other app's usage screen and the part that costs somebody money
            // if they assume otherwise.
            Text("There is no weekly or daily reset. What you use is used until your plan renews.")
        }
    }

    // MARK: - Credits

    private var creditsSection: some View {
        Section {
            Button {
            } label: {
                LabeledContent {
                    Text("Coming soon").foregroundStyle(.tertiary)
                } label: {
                    Text("Buy credits").font(Style.rowTitle)
                }
            }
            .disabled(true)

            Button {
            } label: {
                LabeledContent {
                    Text("Coming soon").foregroundStyle(.tertiary)
                } label: {
                    Text("Upgrade plan").font(Style.rowTitle)
                }
            }
            .disabled(true)
        } header: {
            Text("When you run out")
        } footer: {
            // Honest about the state of it. A live-looking button onto a
            // paywall with no products behind it is worse than a grey one.
            Text("Credits and plans are not on sale yet. When they are, running out will mean buying more or moving up — never waiting for a reset.")
        }
    }

    // MARK: - The way in to the detail

    private var detailSection: some View {
        Section {
            NavigationLink { UsageDetailView() } label: {
                LabeledContent {
                    Text("\(AIUsage.total)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Text("What used it").font(Style.rowTitle)
                }
            }

            NavigationLink { AIPreferencesView() } label: {
                Text("Turn things down").font(Style.rowTitle)
            }
        } footer: {
            Text("Reading is what runs on every message that arrives, so it is the one that adds up.")
        }
    }

    // MARK: - Formatting

    /// Four decimal places, because one classification costs a fraction of a
    /// cent and $0.00 reads as broken.
    static func money(_ amount: Double) -> String {
        amount >= 1
            ? String(format: "$%.2f", amount)
            : String(format: "$%.4f", amount)
    }

    /// The first of next month, which is when a month's allowance comes back.
    private static var renewal: String {
        let calendar = Calendar.current
        guard let next = calendar.date(
            byAdding: .month, value: 1,
            to: calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        ) else { return "" }
        return "Renews \(next.formatted(.dateTime.day().month(.abbreviated)))"
    }
}

/// The per-feature counts, moved off the main screen.
///
/// They answer a real question -- *what* is spending this -- but it is the
/// second question somebody asks, and it was taking four times the room of
/// the first.
struct UsageDetailView: View {
    @State private var isConfirmingReset = false

    private var counts: [(kind: AIUsage.Kind, count: Int)] { AIUsage.used }

    var body: some View {
        List {
            if counts.isEmpty {
                Section {
                    Text("Nothing yet this month.")
                        .font(Style.rowTitle)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(counts, id: \.kind) { row in
                        LabeledContent {
                            Text("\(row.count)")
                                .font(Style.rowTitle.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.kind.title).font(Style.rowTitle)
                                Text(row.kind.detail)
                                    .font(Style.rowDetail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } footer: {
                    // Counted on the phone; the money is counted on the
                    // server. They can disagree, and the reason is worth
                    // saying: a call made on another device is in the money
                    // and not in these.
                    Text("Counted on this phone. The amount on the Usage screen is counted on the server, so it includes your other devices.")
                }
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    Text("Reset these counts")
                        .font(Style.rowTitle)
                        .foregroundStyle(Color.urgent)
                }
            }
        }
        .navigationTitle("What used it")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .alert("Reset the counts?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { AIUsage.reset() }
        } message: {
            Text("Clears this list on this phone. What you have spent is recorded on the server and is not affected.")
        }
    }
}
