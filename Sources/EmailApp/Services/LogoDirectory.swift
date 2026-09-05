import Foundation
import Observation

/// Which picture belongs to which sender, answered by the server.
///
/// 🔴 The phone no longer resolves anything. It used to do a DNS lookup and up
/// to three image fetches **per row, while somebody was scrolling** -- on every
/// device, for every user, forever. Rows filled in one at a time and out of
/// order, and some never arrived. That is what made the inbox look unfinished,
/// and no additional source would have fixed it.
///
/// Gmail and Shortwave resolve on a server, once, for everybody. So does this
/// now: one request carries every sender on screen, the answer is a URL each,
/// and the only thing left on the phone is downloading a picture.
///
/// ## Batched by asking, not by wiring
///
/// Every avatar calls `need(_:)` as it appears, and the requests are collected
/// for a moment before one goes out. That means no screen has to know it
/// should pre-resolve anything -- the inbox, search, the People tab and the
/// chat tiles all batch correctly without a line of code each -- and a
/// screenful is still exactly one round trip.
@MainActor
@Observable
final class LogoDirectory {

    static let shared = LogoDirectory()

    /// Bumped when an answer arrives, so rows drawing a letter redraw.
    private(set) var generation = 0

    /// Domain to picture. A domain that resolved to *nothing* is held as a
    /// miss rather than being absent, or it would be asked for again on every
    /// appearance.
    @ObservationIgnored private var urls: [String: URL] = [:]
    @ObservationIgnored private var known: Set<String> = []

    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    /// Long enough to collect a screenful, short enough that nobody sees the
    /// wait. A list settles well inside this.
    private static let batchWindow: Duration = .milliseconds(120)

    /// The server's own cap. Asking for more in one request is refused, so the
    /// queue is drained in chunks rather than truncated.
    private static let maxPerRequest = 60

    private init() { load() }

    // MARK: - Reading

    /// The picture for a domain, if the answer is already in hand. Never
    /// touches the network: a `View` body calls this.
    func url(for domain: String) -> URL? {
        if !loaded { load() }
        return urls[domain]
    }

    /// Says a domain is on screen. Cheap to call from every row, every time.
    func need(_ domain: String) {
        if !loaded { load() }
        guard !known.contains(domain), !pending.contains(domain) else { return }

        pending.insert(domain)
        // Restarted on each call, so a scrolling list keeps extending the
        // window rather than firing a request per row.
        flush?.cancel()
        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.batchWindow)
            guard !Task.isCancelled else { return }
            await self?.send()
        }
    }

    // MARK: - Asking

    private func send() async {
        guard !pending.isEmpty else { return }

        let batch = Array(pending.prefix(Self.maxPerRequest))
        pending.subtract(batch)

        let answers = await Self.resolve(batch)

        // ⚠️ Every domain asked for is marked known, including the ones that
        // came back empty. Otherwise a company with no logo is re-requested
        // every time its row scrolls past, forever.
        known.formUnion(batch)
        var arrived = false
        for (domain, url) in answers {
            urls[domain] = url
            // Start the download straight away rather than waiting for the row
            // to appear again -- it usually still is.
            AvatarStore.shared.ensure(key: Self.key(for: domain), url: url)
            arrived = true
        }

        save()
        if arrived { generation &+= 1 }

        // Anything the cap left behind.
        if !pending.isEmpty { await send() }
    }

    /// Namespaced so a brand's picture and a person's cannot collide in the
    /// image cache.
    static func key(for domain: String) -> String { "brand-\(domain)" }

    private static func resolve(_ domains: [String]) async -> [String: URL] {
        guard !domains.isEmpty else { return [:] }

        var request = URLRequest(
            url: SupabaseConfig.url.appending(path: "functions/v1/logos")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["domains": domains])
        request.timeoutInterval = 20

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var found: [String: URL] = [:]
        for (domain, value) in payload {
            guard let entry = value as? [String: Any],
                  let text = entry["url"] as? String,
                  let url = URL(string: text)
            else { continue }
            found[domain] = url
        }
        return found
    }

    // MARK: - Disk

    /// Kept between launches so a cold start draws logos immediately instead
    /// of asking again. It is a map of company domains to picture URLs and
    /// nothing else -- no addresses, no messages.
    private static var file: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }

        let folder = base.appendingPathComponent("Maily", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("logos.json")
    }

    private struct Stored: Codable {
        var urls: [String: URL]
        var known: [String]
        var savedAt: Date
    }

    /// How long the phone trusts its own copy before asking again. Shorter
    /// than the server's window on purpose: the server is the cache, and this
    /// only exists so a launch is not blank.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private func load() {
        loaded = true
        guard let file = Self.file,
              let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              Date.now.timeIntervalSince(stored.savedAt) < Self.maxAge
        else { return }

        urls = stored.urls
        known = Set(stored.known)
    }

    private func save() {
        guard let file = Self.file else { return }
        let stored = Stored(urls: urls, known: Array(known), savedAt: .now)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Everything goes when the account does.
    func forgetAll() {
        urls = [:]
        known = []
        pending = []
        if let file = Self.file { try? FileManager.default.removeItem(at: file) }
    }
}
