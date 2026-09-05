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

    // 🔴 From the server, not from Plan.current.
    //
    // Plan.current was hardcoded to free, so the denominator was always the
    // free tier's thirty cents whatever somebody paid. A Pro subscriber who
    // had spent forty cents of their real six dollars was shown "100% used"
    // and a red bar. Every number on this screen now comes from the same
    // verdict the server refuses requests on, so being shown an allowance and
    // then denied it is not possible.
    private var plan: Plan { usage.spend?.tier ?? .free }
    private var fraction: Double { usage.spend?.fraction ?? 0 }
    private var hasCredit: Bool { (usage.spend?.credit ?? 0) > 0 }


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
                    if let end = usage.spend?.period_end {
                        Text("Back on \(end.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(Style.rowDetail)
                            .foregroundStyle(.tertiary)
                    }
                }

                // ⚠️ Said only when it is true, and only for people it is
                // true of. Somebody in billing retry keeps everything they
                // pay for -- cutting them off while their bank sorts itself
                // out is how a customer becomes an ex-customer -- but they do
                // need to know, because in a few days it stops.
                if usage.spend?.is_in_grace == true {
                    Label(
                        "Your last payment did not go through. Everything still works for now.",
                        systemImage: "creditcard.trianglebadge.exclamationmark"
                    )
                    .font(Style.rowDetail)
                    .foregroundStyle(Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
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
            //
            // 🔴 "until your plan renews" was wrong, and expensively so. The
            // allowance window is a calendar month; the subscription renews on
            // its own anniversary. Somebody who subscribed on the 20th read
            // that sentence next to "1 Oct" and had every reason to think they
            // would be charged on the 1st.
            Text("There is no weekly or daily reset. Your allowance comes back on the 1st of each month.")
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

            // 🔴 Only offered to somebody who can actually spend it.
            //
            // Straight from reading Drobe, which sells credit packs to
            // everybody while the code that spends credit sits behind the
            // subscriber gate -- so a non-subscriber can buy something that
            // is unspendable, and the receipt says it does not expire. Money
            // taken for nothing is the one bug that cannot be apologised
            // away, and it is one `if` to not have.
            if plan != .free {
                Button {
                    isShowingPlans = true
                } label: {
                    LabeledContent {
                        Text(hasCredit ? "Add more" : "Top up").foregroundStyle(.secondary)
                    } label: {
                        Text("Buy credits").font(Style.rowTitle)
                    }
                }
            }
        } header: {
            Text("When you run out")
        } footer: {
            Text(plan == .free
                 ? "Credit can be bought on top of a paid plan. It is used after your monthly allowance."
                 : "Credit is used after your monthly allowance, and does not expire while your plan is active.")
        }
    }

    // MARK: - The way in to the detail

    /// 🔴 No call counts here any more.
    ///
    /// There was a "What used it — 92" row and a page of per-feature counts
    /// behind it. Both were `AIUsage`, which lives in `UserDefaults` on one
    /// device and records *before* the request is sent — so it counts calls
    /// that failed, calls that 401'd, and none of the calls made on any other
    /// phone.
    ///
    /// Two units for one idea, and the wrong one was the more prominent. A
    /// person cannot convert "92 requests" into "how much of my plan is
    /// left", and the exact answer to the second question was on screen
    /// directly above it.
    private var detailSection: some View {
        Section {
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
}
