import CryptoKit
import Foundation
import UIKit

/// Which senders get a logo looked up, and the one picture still fetched from
/// the phone.
///
/// 🔴 **The logo hunting is gone from here.** It used to live on the device: a
/// DNS lookup for BIMI, then an `apple-touch-icon` fetch, then two icon
/// services, per row, while somebody was scrolling -- repeated on every device
/// and every reinstall. That is what made the inbox look unfinished. It now
/// happens once on the server for every user; see `LogoDirectory` and the
/// `logos` edge function.
///
/// What is left here is the part that must stay on the phone:
///
/// - **Which domain to ask about**, including stripping `e.tiktok.com` to
///   `tiktok.com`. The server strips too -- it cannot trust a client -- but
///   doing it here as well means one cache entry per company rather than one
///   per sending host.
/// - **Gravatar**, which is keyed on a person's *email address*. Sending
///   addresses to Maily's own server to look up a picture would put a list of
///   who writes to somebody on a server that has no other reason to know. The
///   hash is computed here and goes straight to Gravatar.
enum BrandIcon {

    /// Mail from these is from a person, not a company, so their domain's
    /// logo says nothing about the sender.
    private static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "icloud.com", "me.com", "mac.com", "proton.me",
        "protonmail.com", "aol.com", "gmx.com", "zoho.com", "yandex.com",
    ]

    /// Suffixes that are two labels long, so the organisation is the third
    /// from the end rather than the second.
    ///
    /// Not the full Public Suffix List, which is thousands of entries and a
    /// download to keep current. These are the ones that actually turn up in
    /// mail; anything missed simply keeps a subdomain, which is the behaviour
    /// every domain had before.
    private static let twoLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "co.jp", "or.jp",
        "ne.jp", "ac.jp", "co.kr", "com.au", "net.au", "org.au", "edu.au",
        "co.nz", "com.br", "com.mx", "com.ar", "com.tr", "com.cn", "com.hk",
        "com.sg", "com.tw", "co.in", "co.za", "com.et", "org.et", "edu.et",
    ]

    /// The domain worth looking up for an address, if there is one.
    ///
    /// 🔴 The organisational domain, not the sending host. `e.tiktok.com` is
    /// where the mail came from; `tiktok.com` is who sent it, and is the only
    /// one of the two that any icon service has ever heard of. Getting this
    /// wrong is why newsletters -- the most common kind of message in an inbox
    /// -- had no logo at all.
    static func domain(for address: String) -> String? {
        guard let host = address.split(separator: "@").last?.lowercased(),
              host.contains(".")
        else { return nil }

        let organisation = organisation(of: String(host))
        guard !consumerDomains.contains(organisation) else { return nil }
        return organisation
    }

    static func organisation(of host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        // "news.bbc.co.uk" -> "bbc.co.uk", but "mail.google.com" -> "google.com".
        let keep = twoLabelSuffixes.contains(lastTwo) ? 3 : 2
        guard labels.count > keep else { return host }
        return labels.suffix(keep).joined(separator: ".")
    }

    // MARK: - Gravatar

    /// A person's own picture, where they happen to have published one.
    ///
    /// Keyed on the email address and needs no permission from anybody, which
    /// makes it free to try for exactly the addresses that would otherwise
    /// draw a letter. ⚠️ Most people do not have one -- it is common among
    /// developers and rare elsewhere -- so this is a bonus tier, not a plan
    /// for filling an inbox with faces.
    ///
    /// `d=404` is the important half of the URL: without it Gravatar answers
    /// every miss with a generated pattern, and every person in the inbox gets
    /// a procedural blob instead of their own initial.
    static func gravatarURL(for address: String) -> URL? {
        let normalised = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard normalised.contains("@") else { return nil }

        let digest = SHA256.hash(data: Data(normalised.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(string: "https://www.gravatar.com/avatar/\(digest)?d=404&s=200")
    }

    /// Namespaced so a person's Gravatar and their company's logo cannot
    /// collide in the image cache.
    static func gravatarKey(for address: String) -> String {
        "gravatar-\(address.lowercased())"
    }
}
