import CryptoKit
import Foundation
import UIKit

/// The logo for whoever sent a message, at a size worth drawing.
///
/// 🔴 Rewritten because the old one produced genuinely bad avatars, for two
/// reasons that were each worse than they looked. Measured against real
/// senders before and after:
///
///     tiktok.com     32px  ->  400px
///     stripe.com     32px  ->  256px
///     notion.so      32px  ->  256px
///     airbnb.com     32px  ->  240px
///     e.tiktok.com   nothing at all  ->  400px
///
/// **It asked about the wrong domain.** Companies do not send newsletters from
/// their homepage domain -- they send from `e.tiktok.com`,
/// `notifications.github.com`, `mail.something.com`. Every one of those 404s
/// at every icon service there is, so the single most common kind of message
/// in an inbox got no logo at all and fell back to a letter. The lookup now
/// strips to the organisational domain first.
///
/// **And it settled for 32 pixels.** A 32px icon drawn in a 44pt circle on a
/// 3x screen is being asked to cover 132 pixels: it is a blurry smear, and a
/// list of them looks broken rather than sparse. Sites publish something far
/// better -- `apple-touch-icon.png` is 400×400 on tiktok.com -- so the sources
/// are tried in order of what they are worth and the best one wins.
///
/// ## Why not `AsyncImage`
///
/// Unchanged and still the reason this type exists: the icon services answer
/// an unknown domain with a **404 whose body is a valid PNG** -- a grey
/// placeholder -- and `AsyncImage` renders any decodable body without ever
/// looking at the status code. Both services still do this today; Google's
/// ships a 16×16 PNG with its 404. So: check the status, check the size,
/// remember the misses.
actor BrandIcon {
    static let shared = BrandIcon()

    /// A present-but-nil entry means "looked, found nothing".
    private var cache: [String: UIImage?] = [:]

    /// Below this an icon is a blurry smear at avatar size and the letter
    /// looks better.
    private static let minimumPixels: CGFloat = 32

    /// Good enough to stop looking. Something this size is crisp in the
    /// largest circle the app draws, so paying for more requests to maybe find
    /// a bigger one is work for nothing.
    private static let goodEnoughPixels: CGFloat = 120

    /// Logos change about never, so a cached one is kept for a month.
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

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
    /// mail; anything missed simply keeps a subdomain and looks the icon up
    /// under that, which is what happened for every domain before.
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
    /// one of the two that any icon service has ever heard of.
    nonisolated static func domain(for address: String) -> String? {
        guard let host = address.split(separator: "@").last?.lowercased(),
              host.contains(".")
        else { return nil }

        let organisation = organisation(of: String(host))
        guard !consumerDomains.contains(organisation) else { return nil }
        return organisation
    }

    nonisolated static func organisation(of host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        // "news.bbc.co.uk" -> "bbc.co.uk", but "mail.google.com" -> "google.com".
        let keep = twoLabelSuffixes.contains(lastTwo) ? 3 : 2
        guard labels.count > keep else { return host }
        return labels.suffix(keep).joined(separator: ".")
    }

    // MARK: - Asking

    func icon(for domain: String) async -> UIImage? {
        if let known = cache[domain] { return known }

        if let stored = Self.readFromDisk(domain) {
            cache[domain] = stored
            return stored
        }

        let fetched = await Self.fetchBest(domain)
        cache[domain] = fetched
        Self.writeToDisk(fetched, for: domain)
        return fetched
    }

    /// A person's own picture, where they happen to have published one.
    ///
    /// Gravatar is keyed on the email address and needs no permission from
    /// anybody, which makes it free to try for exactly the addresses that
    /// would otherwise draw a letter. ⚠️ Most people do not have one -- it is
    /// common among developers and rare elsewhere -- so this is a bonus tier,
    /// not a plan for filling an inbox with faces.
    func gravatar(for address: String) async -> UIImage? {
        let key = "gravatar:\(address.lowercased())"
        if let known = cache[key] { return known }

        if let stored = Self.readFromDisk(key) {
            cache[key] = stored
            return stored
        }

        let digest = SHA256.hash(data: Data(address.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        // `d=404` is the important half: without it Gravatar answers every
        // miss with a generated pattern, and every person in the inbox gets a
        // procedural blob instead of their initial.
        let fetched = await Self.load("https://www.gravatar.com/avatar/\(digest)?d=404&s=200")
        cache[key] = fetched
        Self.writeToDisk(fetched, for: key)
        return fetched
    }

    // MARK: - The ladder

    /// Sources in descending order of what they are worth, stopping as soon as
    /// one is good enough.
    private static func fetchBest(_ domain: String) async -> UIImage? {
        // 🔴 BIMI first, because it is the only source that is *authoritative*
        // rather than scraped. The company published this logo itself, against
        // a DMARC-authenticated domain, and for a Verified Mark Certificate a
        // trademark office checked it. It is what Gmail draws.
        //
        // It is also the source that rescues exactly the cases a favicon
        // handles worst. Measured: TikTok's favicon is 32px and eBay's is 16,
        // and both publish a proper BIMI logo.
        if let official = await bimi(domain) { return official }

        let candidates = [
            // Published for the home screen, so it is designed to be looked at
            // rather than squeezed into a browser tab. 400×400 on tiktok.com.
            "https://\(domain)/apple-touch-icon.png",
            "https://\(domain)/apple-touch-icon-precomposed.png",
            // Always has *something* for a domain it knows, up to 256.
            "https://www.google.com/s2/favicons?sz=256&domain=\(domain)",
            // Last, and the only source the old version used.
            "https://icons.duckduckgo.com/ip3/\(domain).ico",
        ]

        var best: UIImage?
        for candidate in candidates {
            guard let image = await load(candidate) else { continue }
            if image.size.width > (best?.size.width ?? 0) { best = image }
            if let best, best.size.width >= goodEnoughPixels { return best }
        }
        return best
    }

    // MARK: - BIMI

    /// The logo a company publishes for its own mail, if it has one.
    ///
    /// The lookup is a DNS TXT record at `default._bimi.<domain>`, which an
    /// app cannot query directly -- Foundation has no DNS API. Google's
    /// DNS-over-HTTPS resolver answers the same question over plain HTTPS,
    /// which is a normal request to a host the app already talks to.
    ///
    /// The record looks like:
    ///
    ///     v=BIMI1; l=https://.../logo.svg; a=https://.../cert.pem
    ///
    /// `l` is the logo. `a` is the certificate proving the trademark, and is
    /// deliberately **not** checked here: verifying a VMC is what decides
    /// whether to show a blue tick, and this only decides which picture to
    /// draw. A domain that publishes a logo under its own DMARC-authenticated
    /// name is a good enough source for an avatar.
    private static func bimi(_ domain: String) async -> UIImage? {
        guard let query = URL(
            string: "https://dns.google/resolve?name=default._bimi.\(domain)&type=TXT"
        ) else { return nil }

        var request = URLRequest(url: query)
        request.timeoutInterval = 6

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONDecoder().decode(DNSAnswer.self, from: data),
              let record = payload.Answer?.compactMap({ $0.data }).first(where: {
                  $0.contains("v=BIMI1")
              })
        else { return nil }

        guard let logo = logoURL(in: record) else { return nil }

        var fetch = URLRequest(url: logo)
        fetch.timeoutInterval = 8
        guard let (svg, logoResponse) = try? await URLSession.shared.data(for: fetch),
              let logoHTTP = logoResponse as? HTTPURLResponse, logoHTTP.statusCode == 200
        else { return nil }

        return await SVGRasterizer.image(from: svg)
    }

    /// Pulls `l=` out of the record.
    ///
    /// The value arrives quoted, sometimes split into several quoted strings
    /// by the resolver, and the separators are inconsistent in the wild --
    /// `v=BIMI1;l=...` and `v=BIMI1; l=...` both occur among the domains
    /// checked. So: unquote, then split on `;`, then trim.
    private static func logoURL(in record: String) -> URL? {
        // ⚠️ Join before unquoting. A TXT record longer than 255 bytes is
        // stored as several strings and comes back as `"...part one" "part
        // two..."`; stripping the quotes first would leave a space in the
        // middle of the URL and quietly produce a broken link. The records
        // seen today are short enough to arrive whole, but a VMC URL is long
        // and one more certificate authority with a longer path would do it.
        let joined = record.replacingOccurrences(of: "\" \"", with: "")
        let unquoted = joined.replacingOccurrences(of: "\"", with: "")
        for field in unquoted.split(separator: ";") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("l=") else { continue }
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            // An empty `l=` is legal and means "we have no logo", which is a
            // deliberate statement rather than a malformed record.
            guard !value.isEmpty, let url = URL(string: value), url.scheme == "https" else {
                return nil
            }
            return url
        }
        return nil
    }

    private struct DNSAnswer: Decodable {
        var Answer: [Record]?
        struct Record: Decodable { var data: String? }
    }

    private static func load(_ string: String) async -> UIImage? {
        guard let url = URL(string: string) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            // ⚠️ A 200 is not proof of an image. Asking a site for
            // `apple-touch-icon.png` it does not have often returns the
            // homepage, or a JSON error, with a perfectly cheerful status.
            guard let image = UIImage(data: data),
                  image.size.width >= minimumPixels,
                  image.size.height >= minimumPixels
            else { return nil }
            return image
        } catch {
            return nil
        }
    }

    // MARK: - Disk

    /// Kept between launches, which is most of what makes the inbox feel
    /// finished. In memory only, every icon in a scrolling list was fetched
    /// again on every cold start -- so the list drew a screen of letters and
    /// then popped, every single time the app opened.
    ///
    /// A miss is recorded too, as an empty file. Without it, four requests are
    /// spent on every launch on every domain that has no logo, which is a
    /// great many of them.
    private static var folder: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }

        let folder = base
            .appendingPathComponent("Maily", isDirectory: true)
            .appendingPathComponent("Brands", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func path(for key: String) -> URL? {
        let safe = key.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return folder?.appendingPathComponent("\(safe).png")
    }

    /// Double optional: nil means "not on disk, go and look", `.some(nil)`
    /// means "looked before, there is nothing".
    private static func readFromDisk(_ key: String) -> UIImage?? {
        guard let path = path(for: key),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        else { return nil }

        if let modified = attributes[.modificationDate] as? Date,
           Date.now.timeIntervalSince(modified) > maxAge {
            return nil
        }

        guard let size = attributes[.size] as? Int, size > 0 else {
            return .some(nil) // The recorded miss.
        }
        guard let data = try? Data(contentsOf: path), let image = UIImage(data: data) else {
            return nil
        }
        return .some(image)
    }

    private static func writeToDisk(_ image: UIImage?, for key: String) {
        guard let path = path(for: key) else { return }
        let data = image?.pngData() ?? Data()
        try? data.write(to: path, options: .atomic)
    }
}
