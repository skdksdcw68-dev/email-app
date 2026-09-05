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
/// counts. The plan comes from StoreKit, and the paywall is `PlansView`.
///
struct AIUsageView: View {
    @Environment(MailStore.self) private var mail

    @State private var usage = UsageStore()
    @State private var isShowingPlans = false

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
        .sheet(isPresented: $isShowingPlans) { PlansView() }
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
                    Text(Self.remaining(fraction))
                        .font(Style.rowDetail)
                        .foregroundStyle(.secondary)
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
                isShowingPlans = true
            } label: {
                LabeledContent {
                    Text(plan == .free ? "See plans" : "Change").foregroundStyle(.secondary)
                } label: {
                    Text(plan == .free ? "Upgrade" : "Your plan").font(Style.rowTitle)
                }
            }

            Button {
                isShowingPlans = true
            } label: {
                LabeledContent {
                    Text("Top up").foregroundStyle(.secondary)
                } label: {
                    Text("Buy credits").font(Style.rowTitle)
                }
            }
        } header: {
            Text("When you run out")
        } footer: {
            Text("Credit is used after your monthly allowance, and does not expire while your plan is active.")
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

    /// 🔴 **No money, anywhere on this screen.**
    ///
    /// It showed "$0.0043 of $6.00", and that is the wrong unit for a person
    /// twice over. It is the *operator's* provider cost, not what they paid,
    /// so it looks like a bill and is not one. And it invites the question a
    /// percentage never does -- why one chat costs two hundred times what
    /// sorting an email costs -- which is a fact about token pricing and not
    /// something anybody signed up to learn.
    ///
    /// The dollars are still tracked exactly, on the server, to four decimal
    /// places. They are the denominator behind this and are never drawn.
    private static func remaining(_ fraction: Double) -> String {
        let left = Int(((1 - fraction) * 100).rounded())
        if left <= 0 { return "None left this month" }
        if left >= 99 { return "Barely touched" }
        return "\(left)% left"
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
