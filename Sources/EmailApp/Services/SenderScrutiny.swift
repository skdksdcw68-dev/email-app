import Foundation

/// Whether the name on a message and the address behind it agree.
///
/// A display name is free text chosen by whoever sent the mail. "PayPal
/// Support" is three words anybody can type, and next to it the real address
/// is drawn small, grey, and often not at all. Every screen in this app that
/// shows a name now has a way to ask this.
///
/// ⚠️ Evidence only, and only what is checkable from the message itself. This
/// does not say a sender is safe -- nothing here can -- and it does not warn
/// on a hunch. A warning that fires on ordinary mail is a warning nobody
/// reads on the one that matters.
enum SenderScrutiny {

    struct Warning: Equatable {
        /// One line, in the reader's words rather than the protocol's.
        let headline: String
        /// The evidence, so somebody can judge it themselves.
        let detail: String
    }

    /// Brands whose name in a display name is worth checking against the
    /// domain. Short and boring on purpose: these are the ones actually
    /// impersonated, and every entry is a name that a real sender would send
    /// from its own domain.
    /// An array rather than a dictionary so the order is fixed: two brands in
    /// one name should always produce the same sentence.
    private static let impersonated: [(token: String, name: String, domains: [String])] = [
        ("paypal", "PayPal", ["paypal.com"]),
        ("apple", "Apple", ["apple.com", "icloud.com"]),
        ("google", "Google", ["google.com", "gmail.com", "youtube.com"]),
        ("microsoft", "Microsoft", ["microsoft.com", "outlook.com", "live.com", "office.com"]),
        ("amazon", "Amazon", ["amazon.com", "amazon.co.uk", "amazon.de"]),
        ("netflix", "Netflix", ["netflix.com"]),
        ("binance", "Binance", ["binance.com"]),
        ("coinbase", "Coinbase", ["coinbase.com"]),
        ("bybit", "Bybit", ["bybit.com"]),
        ("instagram", "Instagram", ["instagram.com"]),
        ("facebook", "Facebook", ["facebook.com", "facebookmail.com"]),
        ("whatsapp", "WhatsApp", ["whatsapp.com"]),
        ("linkedin", "LinkedIn", ["linkedin.com"]),
        ("dhl", "DHL", ["dhl.com", "dhl.de"]),
        ("fedex", "FedEx", ["fedex.com"]),
        ("telebirr", "telebirr", ["ethiotelecom.et"]),
    ]

    static func check(_ contact: Contact) -> Warning? {
        let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = contact.address.lowercased()
        guard !name.isEmpty, address.contains("@") else { return nil }

        let domain = String(address.split(separator: "@").last ?? "")
        guard !domain.isEmpty else { return nil }

        // 1. An address inside the name that is not the address it came from.
        //    "billing@paypal.com <noreply@invoice-2847.top>" reads as PayPal
        //    in every mail client there is.
        if let quoted = firstAddress(in: name), quoted != address {
            let quotedDomain = String(quoted.split(separator: "@").last ?? "")
            if quotedDomain != domain {
                return Warning(
                    headline: "The name shows a different address",
                    detail: "It says \(quoted), but this was sent from \(address)."
                )
            }
        }

        // 2. A brand in the name, sent from somewhere that is not the brand.
        let lowerName = name.lowercased()
        for brand in impersonated where lowerName.contains(brand.token) {
            // A subdomain of the real thing is the real thing:
            // `email.apple.com` and `accounts.google.com` are how these
            // companies actually send mail.
            guard !brand.domains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") })
            else { continue }
            return Warning(
                headline: "This may not be \(brand.name)",
                detail: "The name says \(brand.name), but the address is at \(domain)."
            )
        }

        // 3. A domain that is written to look like another one. `xn--` is a
        //    domain containing characters outside ASCII, which is how "аpple"
        //    with a Cyrillic а reaches an inbox.
        if domain.contains("xn--") {
            return Warning(
                headline: "This address uses look-alike characters",
                detail: "The domain \(domain) is written with characters that can be mistaken for ordinary letters."
            )
        }

        return nil
    }

    /// The first thing in a display name that is shaped like an address.
    private static func firstAddress(in text: String) -> String? {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).lowercased()
    }
}
