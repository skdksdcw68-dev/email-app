import Foundation
import StoreKit
import Observation
import Supabase

/// Buying things, and knowing what has been bought.
///
/// StoreKit 2, so there is no receipt validation to write: `Transaction`
/// arrives already verified by the framework, and `VerificationResult` is the
/// only thing that has to be checked.
///
/// ## What this is not
///
/// 🔴 **Not the source of truth about what somebody is entitled to.** That is
/// the `entitlements` table, written only by Apple's server notifications, and
/// the `ai` function asks the database rather than the phone. A jailbroken
/// device can lie to StoreKit; it cannot lie to a row it has no write policy
/// on.
///
/// What this is for is the *shop*: what is on sale, what it costs in the
/// person's own currency, and putting a purchase through. After a purchase it
/// tells the server directly rather than waiting -- Apple's notification
/// usually lands within seconds but "usually" is not what somebody who just
/// paid should experience.
@MainActor
@Observable
final class Store {

    /// Everything on sale, once loaded.
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    /// What went wrong loading or buying. Shown rather than swallowed.
    private(set) var failure: String?

    /// What StoreKit believes is active on this device, which is what the
    /// paywall reads to show "Current plan". The server decides what is
    /// actually *allowed*.
    private(set) var activePlan: Plan = .free

    /// The listener has to outlive any one screen: a purchase can complete
    /// while the app is in the background, or be approved by a parent hours
    /// later, and the transaction arrives whenever that happens.
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.adopt(result)
            }
        }
    }

    deinit { updates?.cancel() }

    // MARK: - The shop

    private static let identifiers: [String] = [
        "com.netro.maily.pro.monthly",
        "com.netro.maily.pro.yearly",
        "com.netro.maily.max.monthly",
        "com.netro.maily.max.yearly",
        "com.netro.maily.credits.small",
        "com.netro.maily.credits.large",
    ]

    func load() async {
        guard products.isEmpty, !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }

        do {
            products = try await Product.products(for: Self.identifiers)
            await refreshActivePlan()
        } catch {
            // Usually means the products are not approved yet, or the device
            // has no App Store account. Neither is something the person can
            // fix from here, so the paywall says it plainly rather than
            // showing an empty list that looks broken.
            failure = error.localizedDescription
        }
    }

    /// One product by id, for a paywall that knows what it wants to show.
    func product(_ id: String?) -> Product? {
        guard let id else { return nil }
        return products.first { $0.id == id }
    }

    // MARK: - Buying

    enum Outcome {
        case bought
        case cancelled
        /// Waiting on somebody else -- Ask to Buy, or a bank confirmation.
        case pending
    }

    @discardableResult
    func buy(_ product: Product) async throws -> Outcome {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            await adopt(verification)
            return .bought

        case .userCancelled:
            return .cancelled

        case .pending:
            // Ask to Buy on a child account, or a payment the bank wants
            // confirming. The transaction turns up on `Transaction.updates`
            // whenever it is approved, which may be days later.
            return .pending

        @unknown default:
            return .pending
        }
    }

    /// Restores what this Apple ID already owns.
    ///
    /// Required by App Store review for any app selling a subscription, and
    /// genuinely needed: somebody reinstalling on a new phone has bought
    /// nothing new and must not be asked to buy again.
    func restore() async {
        try? await AppStore.sync()
        await refreshActivePlan()
    }

    // MARK: - What is owned

    /// Takes a verified transaction, tells the server, and finishes it.
    private func adopt(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            // Unverified means StoreKit could not prove Apple signed it. Not
            // finished, not trusted, and deliberately silent -- there is
            // nothing a person can do about it and saying so would only
            // alarm.
            return
        }

        await tell(server: transaction)

        // Only after the server has been told. `finish()` is the receipt
        // being torn up: an unfinished transaction is redelivered on the next
        // launch, which is the safety net if the app dies mid-purchase.
        await transaction.finish()
        await refreshActivePlan()
    }

    /// What StoreKit says is active right now, mapped onto a plan.
    private func refreshActivePlan() async {
        var best: Plan = .free

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard let plan = Self.plan(for: transaction.productID) else { continue }
            // Highest tier wins, in case both somehow appear.
            if plan == .max { best = .max } else if best != .max { best = plan }
        }

        activePlan = best
    }

    static func plan(for productID: String) -> Plan? {
        if productID.contains(".max.") { return .max }
        if productID.contains(".pro.") { return .pro }
        return nil
    }

    // MARK: - Telling the server

    /// Hands the signed transaction to the backend so the entitlement is
    /// written without waiting for Apple's notification.
    ///
    /// The **signed** representation, not the parsed fields: the server
    /// verifies Apple's signature itself and trusts nothing the app says
    /// about what was bought. An app that could post `{"plan": "max"}` and be
    /// believed is an app that hands out Max for free.
    private func tell(server transaction: Transaction) async {
        var request = URLRequest(
            url: SupabaseConfig.url.appending(path: "functions/v1/appstore")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(await Self.bearer())", forHTTPHeaderField: "Authorization")
        // `jwsRepresentation` is Apple's own signed JWS for this transaction.
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["signedTransaction": transaction.jwsRepresentation]
        )
        request.timeoutInterval = 20

        // Failing here is survivable and deliberately silent: Apple's server
        // notification writes the same entitlement, so the worst case is the
        // unlock arriving seconds later rather than not at all. Shouting about
        // it would be alarming somebody about something that fixes itself.
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func bearer() async -> String {
        if let session = try? await SupabaseClient.shared.auth.session {
            return session.accessToken
        }
        return SupabaseConfig.anonKey
    }
}
