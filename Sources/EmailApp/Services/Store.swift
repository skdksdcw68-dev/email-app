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
            await syncEntitlements()
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
        // 🔴 The purchase is stamped with who is buying it, at the moment of
        // buying.
        //
        // Apple carries `appAccountToken` through every renewal and into every
        // server notification, and it is the only way a notification arriving
        // hours later -- with no session, no headers and no app running -- can
        // be matched to an account. Without it the webhook has nothing but the
        // Apple ID, which Apple never tells us, so a renewal would write an
        // entitlement for nobody.
        //
        // ⚠️ It must be a UUID, and Supabase user ids already are. A purchase
        // made signed out has none, which the webhook handles by falling back
        // to whoever posts the receipt.
        var options: Set<Product.PurchaseOption> = []
        if let id = await Self.accountToken() {
            options.insert(.appAccountToken(id))
        }

        let result = try await product.purchase(options: options)

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

    /// What a restore actually resolved to.
    enum Restored {
        /// A subscription was found and re-sent to the server.
        case found(Plan)
        /// This Apple ID has nothing to restore.
        case nothing
        /// The App Store could not be reached. **Not** the same as nothing --
        /// telling somebody they own nothing because a network call failed is
        /// how a paying customer is talked into buying twice.
        case unknown(String)
    }

    /// Restores what this Apple ID already owns.
    ///
    /// Required by App Store review for any app selling a subscription, and
    /// genuinely needed: somebody reinstalling on a new phone has bought
    /// nothing new and must not be asked to buy again.
    ///
    /// 🔴 It re-sends the receipt, and it answers honestly.
    ///
    /// Both halves are Drobe's lessons. Drobe's restore reports *"Purchases
    /// restored. Your Pro subscription is active again."* on every outcome
    /// that is not an outright ownership conflict -- including a receipt it
    /// never verified and an answer it never received. And Maily's own
    /// restore used to re-read the local cache and stop there: `AppStore.sync`
    /// does not redeliver finished transactions, so the server heard nothing,
    /// `original_transaction_id` stayed null, and spend fell back to counting
    /// per account -- which is precisely the hole the subscription ledger was
    /// built to close.
    @discardableResult
    func restore() async -> Restored {
        do {
            try await AppStore.sync()
        } catch {
            // A cancelled password prompt lands here too, which is why this
            // is "unknown" and not "nothing".
            return .unknown(error.localizedDescription)
        }

        // Re-send every live entitlement, not just re-read them. This is the
        // half that makes a restore reach the server at all.
        var restored: Plan = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            await tell(signed: result.jwsRepresentation)
            if let plan = Self.plan(for: transaction.productID), plan.rank > restored.rank {
                restored = plan
            }
        }

        await refreshActivePlan()
        return restored == .free ? .nothing : .found(restored)
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

        // The signed JWS lives on the VerificationResult, not on the
        // unwrapped Transaction -- the wrapper is what carries Apple's
        // signature, which is the whole point of sending it.
        await tell(signed: result.jwsRepresentation)

        // Only after the server has been told. `finish()` is the receipt
        // being torn up: an unfinished transaction is redelivered on the next
        // launch, which is the safety net if the app dies mid-purchase.
        await transaction.finish()
        await refreshActivePlan()
    }

    /// Exactly which products this Apple ID currently holds.
    ///
    /// The paywall needs the product, not just the tier: somebody on Pro
    /// monthly does not own Pro yearly, and telling them they do hides the
    /// only upgrade the screen exists to offer.
    private(set) var ownedProductIDs: Set<String> = []

    /// Whether an introductory offer is still available to this Apple ID for
    /// a product.
    ///
    /// ⚠️ Eligibility is per Apple ID and per *subscription group*, not per
    /// product, and StoreKit is the only thing that knows. Assuming it -- as
    /// the paywall did -- promises a free trial to somebody who used theirs a
    /// year ago and then charges them on the spot.
    private(set) var trialEligibleIDs: Set<String> = []

    func offersTrial(for id: String?) -> Bool {
        guard let id else { return false }
        return trialEligibleIDs.contains(id)
    }

    /// Re-presents what this Apple ID holds, so an entitlement cannot be
    /// stranded on the device.
    ///
    /// 🔴 The case this exists for: Maily works signed out, so somebody can
    /// reach the paywall and buy with no Supabase account. The purchase then
    /// carries no `appAccountToken` and there is no bearer to fall back on, so
    /// the server has nothing to write it against -- and nothing would ever
    /// send it again. They would have paid, and be on Free, until they
    /// happened to find Restore.
    ///
    /// Replay is free by design: the receipt is Apple's, the write is an
    /// upsert of the same state, and consumables are gated on a transaction
    /// id that has already been recorded.
    private func syncEntitlements() async {
        guard await Backend.isSignedIn else { return }
        for await result in Transaction.currentEntitlements {
            guard case .verified = result else { continue }
            await tell(signed: result.jwsRepresentation)
        }
    }

    /// What StoreKit says is active right now, mapped onto a plan.
    private func refreshActivePlan() async {
        var best: Plan = .free
        var owned: Set<String> = []

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            owned.insert(transaction.productID)
            guard let plan = Self.plan(for: transaction.productID) else { continue }
            // Highest tier wins, in case both somehow appear.
            if plan == .max { best = .max } else if best != .max { best = plan }
        }

        activePlan = best
        ownedProductIDs = owned
        await refreshTrialEligibility()
    }

    private func refreshTrialEligibility() async {
        var eligible: Set<String> = []

        for product in products {
            guard let subscription = product.subscription else { continue }
            // `isEligibleForIntroOffer` is asked of the *group*, and a product
            // with no introductory offer configured can never be eligible
            // however the group answers.
            guard subscription.introductoryOffer != nil else { continue }
            if await subscription.isEligibleForIntroOffer {
                eligible.insert(product.id)
            }
        }

        trialEligibleIDs = eligible
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
    private func tell(signed jws: String) async {
        var request = URLRequest(
            url: SupabaseConfig.url.appending(path: "functions/v1/appstore")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(await Self.bearer())", forHTTPHeaderField: "Authorization")
        // `jwsRepresentation` is Apple's own signed JWS for this transaction.
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["signedTransaction": jws]
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

    /// The signed-in person's id, as the UUID Apple will carry.
    ///
    /// Nil when signed out, which is a real state: Maily works without an
    /// account, so somebody can reach the paywall with no user to bind to.
    private static func accountToken() async -> UUID? {
        try? await Backend.userID()
    }
}
