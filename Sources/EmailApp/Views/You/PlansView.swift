import SwiftUI
import StoreKit

/// The two plans, and what they cost.
///
/// Annual first, with a switch for monthly -- Abel's call, and the right one:
/// annual is the better deal and the one worth showing, and somebody who wants
/// monthly knows they want monthly and will find the switch. Leading with
/// monthly makes the annual saving invisible to everybody who does not go
/// looking.
///
/// ⚠️ Prices come from StoreKit, never from `Plan.priceTier` or anything else
/// hardcoded here. `Product.displayPrice` is already in the person's own
/// currency, already formatted for their region, and already correct if Apple
/// changes a tier. Anything typed into this file would be wrong for most of
/// the world on the day it shipped.
struct PlansView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var store = Store()
    @State private var isYearly = true
    @State private var busy: String?
    @State private var note: String?
    @State private var isManaging = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    billingToggle
                    ForEach(Plan.purchasable) { plan in
                        card(for: plan)
                    }
                    creditsRow
                    manageRow
                    smallPrint
                }
                .screenGutter()
                .padding(.bottom, Style.loose)
            }
            .navigationTitle("Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FlowCloseButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") {
                        Task { await restore() }
                    }
                    .font(Style.rowDetail)
                }
            }
        }
        .task { await store.load() }
        .manageSubscriptionsSheet(isPresented: $isManaging)
        .alert("Store", isPresented: .constant(note != nil)) {
            Button("OK") { note = nil }
        } message: {
            Text(note ?? "")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 6) {
            Text(store.activePlan == .free ? "Get more out of Maily" : "You are on \(store.activePlan.title)")
                .font(Style.stepTitle)
                .multilineTextAlignment(.center)
            Text("Maily reads, sorts and writes with AI. A plan is how much of that you get each month.")
                .font(Style.rowDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Style.tight)
    }

    private var billingToggle: some View {
        Picker("Billing", selection: $isYearly) {
            Text("Yearly").tag(true)
            Text("Monthly").tag(false)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func card(for plan: Plan) -> some View {
        let id = isYearly ? plan.yearlyProductID : plan.monthlyProductID
        let product = store.product(id)
        // 🔴 The *product*, not the tier.
        //
        // Comparing tiers meant somebody on Pro monthly who flipped this
        // screen to Yearly saw the Pro yearly card labelled "Your plan" with
        // the button disabled -- for something they do not own, and with no
        // other way in the app to switch. The upsell the whole screen is
        // arranged around was unreachable by the people it was aimed at.
        let isCurrent = store.ownedProductIDs.contains(id ?? "")

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.title)
                    .font(Style.screenTitle)
                Spacer(minLength: 8)
                if isCurrent {
                    Text("Current")
                        .font(Style.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }

            if let product {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.title2.bold())
                    Text(isYearly ? "per year" : "per month")
                        .font(Style.rowDetail)
                        .foregroundStyle(.secondary)
                    if isYearly, let saving = Self.saving(for: plan, in: store) {
                        Text(saving)
                            .font(Style.caption.weight(.semibold))
                            .foregroundStyle(Color.ok)
                    }
                }
            } else if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("Not available")
                    .font(Style.rowDetail)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Self.features(of: plan), id: \.self) { line in
                    Label(line, systemImage: "checkmark")
                        .font(Style.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                guard let product else { return }
                Task { await purchase(product) }
            } label: {
                Group {
                    if busy == id {
                        ProgressView().tint(.white)
                    } else {
                        Text(Self.label(
                            isCurrent: isCurrent,
                            isYearly: isYearly,
                            plan: plan,
                            current: store.activePlan,
                            offersTrial: store.offersTrial(for: id)
                        ))
                        .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(product == nil || isCurrent || busy != nil)
        }
        .padding(Style.rowGutter)
        .cardBackground()
        .overlay {
            // The higher tier gets the ring, so the eye lands there first.
            if plan == .max {
                RoundedRectangle(cornerRadius: Style.card, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
            }
        }
    }

    /// 🔴 Shown only to somebody who has a plan to spend it on.
    ///
    /// Drobe sells these packs to everybody, while the code that *spends*
    /// credit sits behind its subscriber gate. So a non-subscriber can buy
    /// credit that nothing will ever draw on, and the copy promises it does
    /// not expire. Taking money for something unusable is the one failure
    /// that cannot be fixed with an apology, and avoiding it here costs a
    /// single condition.
    @ViewBuilder
    private var creditsRow: some View {
        if store.activePlan != .free {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run out early?")
                    .font(Style.rowTitleStrong)
                Text("Top up without changing plan. Credit is used after your monthly allowance and does not expire while your plan is active.")
                    .font(Style.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Style.tight) {
                    ForEach(["com.netro.maily.credits.small", "com.netro.maily.credits.large"], id: \.self) { id in
                        if let product = store.product(id) {
                            Button {
                                Task { await purchase(product) }
                            } label: {
                                VStack(spacing: 2) {
                                    Text(product.displayName).font(Style.rowDetail)
                                    Text(product.displayPrice).font(Style.rowTitleStrong)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .disabled(busy != nil)
                        }
                    }
                }
            }
            .padding(Style.rowGutter)
            .cardBackground()
        }
    }

    /// The way out, for somebody who already pays.
    ///
    /// Drobe's lesson, and an App Store one: its Restore button renders only
    /// in the *not*-subscribed branch, while its subscribed flag survives up
    /// to a week on a cached snapshot. The lapsed subscriber -- exactly the
    /// person its own error message tells to tap Restore -- gets a screen
    /// with no Restore on it. Here Restore is in the toolbar unconditionally,
    /// and cancelling is one tap rather than a hunt through Settings.
    @ViewBuilder
    private var manageRow: some View {
        if store.activePlan != .free {
            Button {
                isManaging = true
            } label: {
                Text("Manage or cancel subscription")
                    .font(Style.rowDetail)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
        }
    }

    private var smallPrint: some View {
        VStack(spacing: 6) {
            if let failure = store.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Style.caption)
                    .foregroundStyle(Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Required by App Store review, and true: a subscription that
            // renews silently and cannot be found is the single most common
            // reason these get rejected.
            Text("Subscriptions renew automatically until cancelled. Manage or cancel any time in your Apple account settings.")
                .font(Style.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Acting

    private func purchase(_ product: Product) async {
        busy = product.id
        defer { busy = nil }

        do {
            switch try await store.buy(product) {
            case .bought:
                dismiss()
            case .cancelled:
                break
            case .pending:
                note = "That is waiting for approval. It will unlock on its own once it goes through."
            }
        } catch {
            note = error.localizedDescription
        }
    }

    /// 🔴 Says what actually happened, including when nothing did.
    ///
    /// Drobe's restore congratulates you on all three of "found", "found
    /// nothing" and "could not ask" -- so somebody whose subscription is
    /// genuinely gone is told it is active again, and goes on believing that
    /// until the next refusal. Three outcomes, three sentences.
    private func restore() async {
        switch await store.restore() {
        case .found(let plan):
            note = "Restored. You are on \(plan.title)."
        case .nothing:
            note = "This Apple ID has no Maily subscription to restore. If you paid with a different Apple ID, sign in to that one in Settings and try again."
        case .unknown(let reason):
            note = "Could not check with the App Store: \(reason)"
        }
    }

    // MARK: - Words

    /// What the button says.
    ///
    /// 🔴 The trial half is an App Store review risk as much as a fairness
    /// one. Every yearly button used to promise "Start 3-day free trial"
    /// unconditionally, without asking StoreKit whether this Apple ID is
    /// still eligible. Somebody who has already used their trial was promised
    /// another and charged immediately -- which is a rejection at review, and
    /// a refund request from anyone who slips past it.
    ///
    /// The downgrade half matters for a different reason: moving from Max to
    /// Pro takes effect at the end of the period somebody has already paid
    /// for. "Choose Pro" implies it happens now, and then nothing visibly
    /// changes for a month.
    static func label(
        isCurrent: Bool,
        isYearly: Bool,
        plan: Plan,
        current: Plan,
        offersTrial: Bool
    ) -> String {
        if isCurrent { return "Your plan" }
        if current != .free && plan.rank > current.rank { return "Switch at renewal" }
        if isYearly && offersTrial { return "Start free trial" }
        return "Choose \(plan.title)"
    }

    private static func features(of plan: Plan) -> [String] {
        switch plan {
        case .free:
            return []
        case .pro:
            return [
                "Up to 3 mailboxes",
                "Sorting, summaries and drafting",
                "Auto-Reply",
            ]
        case .max:
            // 🔴 "The faster model for chat and drafting" used to be here and
            // is gone, because it was not true. `ai/index.ts` sends every
            // caller to `gpt-5.6-luna` -- free accounts included -- so Max was
            // being sold something everybody already had.
            //
            // The two ways to fix that are to make it true or to stop saying
            // it, and making it true here means giving Pro subscribers a
            // *worse* writer than they have today. That model was chosen by
            // reading what the candidates actually wrote: the others invented
            // a day rate nobody gave them and read a meeting time back to the
            // person who set it. Degrading paying subscribers' drafting in
            // order to sell a higher tier is not a trade worth making, so the
            // sentence goes instead.
            return [
                "Unlimited mailboxes",
                usageClaim(for: plan),
                "Everything in Pro",
            ]
        }
    }

    /// "2.5x the usage of Pro", worked out from the two allowances the server
    /// actually enforces on.
    ///
    /// 🔴 Not a typed string. It used to say "roughly twice", which was true of
    /// an $11 ceiling and stopped being true the moment Max moved to $15 --
    /// a paywall promising less than it gives is only luck, and the same edit
    /// in the other direction is a claim nobody can honour. Deriving it means
    /// the sentence cannot outlive the number.
    private static func usageClaim(for plan: Plan) -> String {
        let times = plan.timesPro
        // One decimal, but no ".0" -- "2.5x" and "3x", never "3.0x".
        let text = times == times.rounded()
            ? String(Int(times))
            : String(format: "%.1f", times)
        return "\(text)x the AI usage of Pro"
    }

    /// Worked out from the two real prices rather than written down, so it
    /// cannot disagree with what is actually charged.
    private static func saving(for plan: Plan, in store: Store) -> String? {
        guard let yearly = store.product(plan.yearlyProductID),
              let monthly = store.product(plan.monthlyProductID)
        else { return nil }

        // `Product.price` is a `Decimal`, which is the right type for money
        // and the wrong one for arithmetic with untyped literals -- `* 12`
        // inferred `Float16` and would not compile. Explicit both ways, and
        // converted to `Double` only for the final rounding.
        let twelve = monthly.price * Decimal(12)
        guard twelve > 0, yearly.price < twelve else { return nil }

        let saved = (twelve - yearly.price) / twelve
        let percent = Int((NSDecimalNumber(decimal: saved).doubleValue * 100).rounded())
        guard percent > 0 else { return nil }
        return "Save \(percent)% versus monthly"
    }
}
