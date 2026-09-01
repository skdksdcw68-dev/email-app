import SwiftUI
import UIKit

/// What kind of relationship this is.
///
/// Two tiers, deliberately. The first four -- colleague, personal, external,
/// service -- are the only ones Maily ever *infers*, because they come from
/// signals that are actually present (the domain, the local part, bulk
/// headers) and are right most of the time. The rest exist for the user to
/// assign by hand on a person's page: "client" versus "friend" versus
/// "school" is context that is usually not in the emails at all, so a model
/// asked to pick between them guesses -- confidently, and often wrong.
enum PersonCategory: String, CaseIterable, Identifiable, Codable {
    // Inferred.
    case colleague
    case personal
    case external
    case service

    // The user's to say.
    case client
    case family
    case friend
    case school

    var id: Self { self }

    var title: String {
        switch self {
        case .colleague: "Colleague"
        case .personal:  "Personal"
        case .external:  "External"
        case .service:   "Service"
        case .client:    "Client"
        case .family:    "Family"
        case .friend:    "Friend"
        case .school:    "School"
        }
    }

    var systemImage: String {
        switch self {
        case .colleague: "building.2.fill"
        case .personal:  "heart.fill"
        case .external:  "briefcase.fill"
        case .service:   "gearshape.fill"
        // "handshake" is not an SF Symbol; the picker showed a blank where
        // the glyph should have been.
        case .client:    "signature"
        case .family:    "house.fill"
        case .friend:    "face.smiling.fill"
        case .school:    "graduationcap.fill"
        }
    }

    var color: Color {
        switch self {
        case .colleague: Color(uiColor: .systemBlue)
        case .personal:  Color(uiColor: .systemPink)
        case .external:  Color(uiColor: .systemIndigo)
        case .service:   Color(uiColor: .systemGray)
        case .client:    Color(uiColor: .systemGreen)
        case .family:    Color(uiColor: .systemOrange)
        case .friend:    Color(uiColor: .systemCyan)
        case .school:    Color(uiColor: .systemPurple)
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

    /// Worked out locally, from the address and the mail itself. Only ever
    /// lands on one of the four inferred cases; the hand-assigned ones come
    /// exclusively from the picker on a person's page.
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
