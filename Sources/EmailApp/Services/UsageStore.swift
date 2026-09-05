import Foundation
import Observation

/// What the AI has actually cost this person, in money.
///
/// `AIUsage` counts *calls*, on the phone, because that is all the phone can
/// know. This reads the figure the server priced from OpenAI's own token
/// counts -- input, cached input and output at their separate rates -- which
/// is the only number that means anything once there is a plan to spend
/// against.
///
/// The counts stay: they are instant, they work offline, and they say which
/// features are doing the spending. This says how much.
@MainActor
@Observable
final class UsageStore {

    /// What one person has spent, as the server has it.
    struct Spend: Codable, Equatable {
        var month_usd: Double?
        var total_usd: Double?
        var calls: Int?
        var last_call_at: Date?

        var thisMonth: Double { month_usd ?? 0 }
        var allTime: Double { total_usd ?? 0 }
    }

    private(set) var spend: Spend?
    private(set) var isLoading = false
    /// Set when the figure could not be fetched. Shown rather than swallowed:
    /// a spend screen that silently shows zero is worse than one that says it
    /// could not check.
    private(set) var failure: String?

    /// When the figure was last fetched, so the screen can say how fresh it is
    /// rather than implying it is live.
    private(set) var checkedAt: Date?

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }

        guard await Backend.isSignedIn else {
            failure = "Sign in to see what you have used."
            return
        }

        do {
            let rows: [Spend] = try await Backend.select(
                "my_ai_spend", query: "select=month_usd,total_usd,calls,last_call_at"
            )
            // No rows means nothing has been spent yet, which is a zero rather
            // than a failure -- the view only has a row once there is usage.
            spend = rows.first ?? Spend()
            checkedAt = .now
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// What somebody is paying for, and therefore how much they may spend.
///
/// ⚠️ **Nothing here is purchasable yet.** There is no StoreKit, no product in
/// App Store Connect, and no entitlement table -- so `current` is always
/// `.free` and the allowance below is what the free tier gets. The screen is
/// built against this type so that wiring a real purchase later changes one
/// property rather than a screen.
///
/// The numbers are deliberately the operator's cost, not a price. What a plan
/// *sells* for is a decision nobody has made yet; what it may *cost* is
/// already knowable, because every call is priced from the provider's own
/// token counts.
enum Plan: String, Codable, CaseIterable, Identifiable {
    case free, pro, max

    var id: Self { self }

    var title: String {
        switch self {
        case .free: "Free"
        case .pro:  "Pro"
        case .max:  "Max"
        }
    }

    /// How much AI a plan may use in a month, in dollars of provider cost.
    ///
    /// 🔴 **Never shown to anybody.** This is the denominator behind a
    /// percentage and nothing else -- see the note on `AIUsageView`. It is the
    /// operator's cost, not a price, and the two are not the same number:
    /// Apple takes its cut of the price before any of it arrives.
    ///
    /// Set against real measured costs. A message sorted by `gpt-5-nano` runs
    /// about $0.00005 and a chat exchange on `gpt-5.6-luna` about $0.009, so
    /// $6 is roughly six hundred chat exchanges in a month -- far more than a
    /// heavy user reaches, which is the point of a ceiling nobody normally
    /// touches.
    var monthlyAllowanceUSD: Double {
        switch self {
        case .free: 0.30
        case .pro:  6
        case .max:  20
        }
    }

    /// What it sells for. Shown only as Apple's own localised price string at
    /// the point of purchase -- this is here so the tiers are written down in
    /// one place, not to be drawn.
    var priceTier: String {
        switch self {
        case .free: "—"
        case .pro:  "14.99"
        case .max:  "39.99"
        }
    }

    /// The one Maily runs on today.
    ///
    /// 🔴 Hardcoded, and it must stay obvious that it is. When entitlements
    /// exist this reads them; until then, pretending to know somebody's plan
    /// would mean a paywall that fires on a purchase that cannot be made.
    static var current: Plan { .free }
}
