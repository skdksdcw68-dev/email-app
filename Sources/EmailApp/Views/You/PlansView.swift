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
                        Task { await store.restore() }
                    }
                    .font(Style.rowDetail)
                }
            }
        }
        .task { await store.load() }
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
        let isCurrent = store.activePlan == plan

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
                        Text(isCurrent ? "Your plan" : (isYearly ? "Start 3-day free trial" : "Choose \(plan.title)"))
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

    private var creditsRow: some View {
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

    // MARK: - Words

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
            return [
                "Unlimited mailboxes",
                "The faster model for chat and drafting",
                "Roughly twice the monthly allowance",
                "Everything in Pro",
            ]
        }
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
