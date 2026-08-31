import SwiftUI
import UIKit

/// What kind of relationship this is.
///
/// Deliberately four, not nine. "Client" versus "lead" versus "customer" is
/// business context that is usually not in the emails at all, so a model asked
/// to pick between them guesses -- confidently, and often wrong. These four
/// come from signals that are actually present, are right most of the time,
/// and cost nothing to work out. Anything finer is the user's to say.
enum PersonCategory: String, CaseIterable, Identifiable, Codable {
    case colleague
    case personal
    case external
    case service

    var id: Self { self }

    var title: String {
        switch self {
        case .colleague: "Colleague"
        case .personal:  "Personal"
        case .external:  "External"
        case .service:   "Service"
        }
    }

    var systemImage: String {
        switch self {
        case .colleague: "building.2.fill"
        case .personal:  "heart.fill"
        case .external:  "briefcase.fill"
        case .service:   "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .colleague: Color(uiColor: .systemBlue)
        case .personal:  Color(uiColor: .systemPink)
        case .external:  Color(uiColor: .systemIndigo)
        case .service:   Color(uiColor: .systemGray)
        }
    }

    /// Anything the user is unlikely to have a relationship with. Kept out of
    /// the main list, because forty noreply addresses are not "people".
    var isPerson: Bool { self != .service }

    private static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "icloud.com", "me.com", "mac.com", "proton.me",
        "protonmail.com", "aol.com", "gmx.com", "zoho.com", "yandex.com",
    ]

    private static let serviceLocalParts = [
        "noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon",
        "notifications", "notification", "support@", "billing@", "info@",
        "hello@", "team@", "updates", "alerts", "postmaster", "bounce",
    ]

    /// Worked out locally, from the address and the mail itself.
    ///
    /// `myDomain` is the user's own domain -- someone on it is a colleague,
    /// which is the single most reliable signal available and the reason this
    /// is worth doing without a model at all.
    static func inferred(
        for address: String,
        myDomain: String?,
        isBulk: Bool = false
    ) -> PersonCategory {
        let lowered = address.lowercased()

        if isBulk { return .service }
        if serviceLocalParts.contains(where: lowered.contains) { return .service }

        guard let domain = lowered.split(separator: "@").last.map(String.init) else {
            return .external
        }

        // A shared consumer domain says nothing -- everyone is on gmail.com --
        // so it only counts as "colleague" on a real company domain.
        if let myDomain, domain == myDomain, !consumerDomains.contains(domain) {
            return .colleague
        }
        if consumerDomains.contains(domain) { return .personal }
        return .external
    }
}
