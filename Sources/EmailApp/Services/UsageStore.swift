import Foundation
import Observation

/// What the AI has actually cost this person, in money.
///
/// 🔴 **The same answer the server enforces on, not a second opinion.**
///
/// This used to read a view that summed usage by *account*, while the ceiling
/// is counted by *subscription*. After a subscription moves between accounts
/// those are two different totals by design -- so the number on screen and
/// the number a request is refused on could not agree, and the screen was the
/// one that was wrong.
///
/// `my_spend()` calls the very function the edge function calls. One source,
/// so being shown an allowance and then refused it is not possible.
@MainActor
@Observable
final class UsageStore {

    /// The verdict, exactly as `spend_check` returns it.
    struct Spend: Codable, Equatable {
        var plan: String?
        var allowance_usd: Double?
        var spent_usd: Double?
        var credit_usd: Double?
        var is_allowed: Bool?
        /// When the allowance comes back. A calendar month, from the server's
        /// clock -- the same boundary the ledger sums from.
        var period_end: Date?
        /// When Apple next charges. A different date entirely, and null on
        /// free because nothing renews.
        var renews_at: Date?
        var is_in_grace: Bool?

        var spent: Double { spent_usd ?? 0 }
        /// Bought credit counts towards what is left, so it belongs in the
        /// denominator. Without it, topping up moved no bar and looked like
        /// nothing had happened.
        var allowance: Double { (allowance_usd ?? 0) + (credit_usd ?? 0) }
        var credit: Double { credit_usd ?? 0 }

        /// Exactly what it says: dollars spent over dollars allowed. $1 of a
        /// $10 allowance is 10%, not "about a tenth".
        var fraction: Double {
            guard allowance > 0 else { return 1 }
            return min(1, spent / allowance)
        }

        var tier: Plan { Plan(rawValue: plan ?? "free") ?? .free }
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
            // An RPC rather than a table read. `spend_check(uuid)` stays
            // revoked from `authenticated` -- a caller that could pass any id
            // could read anybody's spend -- and `my_spend()` takes no
            // argument, reading `auth.uid()` itself.
            let rows: [Spend] = try await Backend.rpc("my_spend")
            spend = rows.first ?? Spend()
            checkedAt = .now
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// What somebody is paying for, and therefore how much they may spend.
///
/// The numbers below are the operator's *cost*, not a price, and the two are
/// never the same: Apple takes its cut of the price before any of it arrives.
/// Nothing here is ever shown to a person -- it is the denominator behind a
/// percentage, and see `AIUsageView` for why it stays that way.
///
/// ⚠️ Which plan somebody is on is **not** here. It comes from the server, via
/// `UsageStore.Spend.tier`, because a device can be wrong about it in both
/// directions -- a lapsed subscription still reads as active in StoreKit's
/// cache, and a restore moves an entitlement to an account that did not pay.
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
    ///
    /// The margins these leave, after Apple's 15%:
    ///
    ///     Pro  $14.99 -> $12.74 net, $6 ceiling  -> 53%
    ///     Max  $29.99 -> $25.49 net, $15 ceiling -> 41%
    var monthlyAllowanceUSD: Double {
        switch self {
        case .free: 0.30
        case .pro:  6
        case .max:  15
        }
    }

    /// How many mailboxes may be connected.
    ///
    /// The business signal, and the reason Max is not just "more of the same".
    /// An agency or a small team runs many addresses; one person runs one or
    /// two. Multi-mailbox already works, so this is a limit rather than a
    /// feature -- which is the cheap kind of tier to draw.
    var mailboxLimit: Int {
        switch self {
        case .free: 1
        case .pro:  3
        case .max:  .max
        }
    }

    // 🔴 `usesPriorityModel` was here and is deleted rather than fixed.
    //
    // Nothing read it. The server sends every caller to `gpt-5.6-luna`
    // whatever they pay, so the property described a difference that did not
    // exist -- and it was on the paywall as "the faster model for chat and
    // drafting", which made it a claim rather than a stub. A flag nobody
    // checks reads as a feature that is switched on somewhere else, which is
    // how it ended up being sold.
    //
    // If Max should get a better writer, that is a model with its own seeded
    // price row, and the paywall line comes back with it.

    /// The App Store product this plan is bought as. Nil for free, which is
    /// not bought.
    var monthlyProductID: String? {
        switch self {
        case .free: nil
        case .pro:  "com.netro.maily.pro.monthly"
        case .max:  "com.netro.maily.max.monthly"
        }
    }

    var yearlyProductID: String? {
        switch self {
        case .free: nil
        case .pro:  "com.netro.maily.pro.yearly"
        case .max:  "com.netro.maily.max.yearly"
        }
    }

    /// Everything that can be bought, highest tier first -- which is the order
    /// a paywall shows them in.
    static var purchasable: [Plan] { [.max, .pro] }

    /// Where this sits against the others. Higher is more.
    ///
    /// Used to tell an upgrade from a downgrade, which decide differently:
    /// an upgrade takes effect immediately with proration, a downgrade waits
    /// for the end of the period already paid for.
    var rank: Int {
        switch self {
        case .free: 0
        case .pro:  1
        case .max:  2
        }
    }

    /// How many times this plan's allowance is Pro's. The paywall says "2.5x
    /// the usage of Pro" from this rather than from a typed string, so the
    /// claim cannot drift from the ceiling that is actually enforced.
    var timesPro: Double {
        let pro = Plan.pro.monthlyAllowanceUSD
        guard pro > 0 else { return 1 }
        return monthlyAllowanceUSD / pro
    }

}
