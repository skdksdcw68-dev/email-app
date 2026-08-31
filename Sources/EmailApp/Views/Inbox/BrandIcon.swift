import UIKit

/// Looks up a sender's brand icon, or decides there isn't one.
///
/// This cannot be `AsyncImage`. The icon service answers an unknown domain
/// with a 404 whose *body is still a valid PNG* -- a grey chevron placeholder
/// -- and AsyncImage renders any decodable body without ever looking at the
/// status code. The result was every unknown sender wearing the same grey
/// chevron, which is the exact failure the service was chosen to avoid.
///
/// So: check the status, check the size, and remember the misses.
actor BrandIcon {
    static let shared = BrandIcon()

    /// A present-but-nil entry means "looked, found nothing". Worth storing:
    /// without it every miss is refetched each time a row scrolls back on.
    private var cache: [String: UIImage?] = [:]

    /// Below this an icon is a blurry smear at avatar size and the letter
    /// looks better. Plenty of sites still serve a 16pt favicon.
    private static let minimumPixels: CGFloat = 32

    /// Mail from these is from a person, not a company, so their domain's
    /// logo says nothing about the sender.
    private static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "icloud.com", "me.com", "mac.com", "proton.me",
        "protonmail.com", "aol.com", "gmx.com", "zoho.com", "yandex.com",
    ]

    /// The domain worth looking up for an address, if there is one.
    nonisolated static func domain(for address: String) -> String? {
        guard let host = address.split(separator: "@").last?.lowercased(),
              host.contains("."),
              !consumerDomains.contains(host)
        else { return nil }
        return host
    }

    func icon(for domain: String) async -> UIImage? {
        if let known = cache[domain] { return known }
        let fetched = await fetch(domain)
        cache[domain] = fetched
        return fetched
    }

    private func fetch(_ domain: String) async -> UIImage? {
        guard let url = URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico") else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let image = UIImage(data: data),
                  image.size.width >= Self.minimumPixels,
                  image.size.height >= Self.minimumPixels
            else { return nil }
            return image
        } catch {
            return nil
        }
    }
}
