import Foundation
import Observation

/// Photographs of the people who write to you, from Google Contacts.
///
/// 🔴 **Mail scopes carry no photograph of a sender.** Gmail's own app shows
/// faces because it has the person's *Contacts*, which is a different API and
/// a different permission from reading mail -- so an app with mail access
/// alone has nothing to draw and a coloured letter is the honest answer. This
/// is the other half of that sentence: with `contacts.readonly` granted, the
/// photographs exist and can be shown.
///
/// ## What it does and does not cover
///
/// ⚠️ Only people actually **in** somebody's Google Contacts. That is usually
/// colleagues, friends and family -- not the hundred newsletters and
/// no-reply addresses that make up most of an inbox. Google's "Other
/// contacts", the auto-collected list of everyone you have ever emailed, is
/// reachable through `otherContacts.list` but **carries no photos at all**:
/// its `readMask` accepts names, email addresses and phone numbers, and
/// nothing else. So this cannot be made to cover everybody, and companies
/// keep their brand mark from `BrandIcon`.
///
/// ## Why the whole list, once
///
/// One request per day per mailbox rather than a lookup per sender. A
/// per-sender call would be a network round trip for every row of a scrolling
/// list, against an API with a quota, to answer a question whose whole answer
/// fits in a few kilobytes. The map is address to photo URL; `AvatarStore`
/// holds the images themselves.
@MainActor
@Observable
final class PeopleDirectory {

    static let shared = PeopleDirectory()

    /// Bumped when a fetch adds anybody, so lists redraw with the new faces.
    private(set) var generation = 0

    /// Lowercased address to photo URL. Deliberately small: a thousand
    /// contacts is a few tens of kilobytes of string.
    @ObservationIgnored private var photos: [String: URL] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var isFetching = false

    /// Google's page size limit for `connections.list`.
    private static let pageSize = 1000
    /// Beyond this, stop paging. Somebody with more contacts than this has an
    /// address book that is not really an address book, and the tail of it is
    /// not who is emailing them today.
    private static let maxPages = 5
    private static let maxAge: TimeInterval = 24 * 60 * 60

    private init() { load() }

    // MARK: - Reading

    /// The photo for an address, if there is one. Never touches the network:
    /// a `View` body calls this.
    func photo(for address: String) -> URL? {
        if !loaded { load() }
        return photos[address.lowercased()]
    }

    // MARK: - Fetching

    /// Refreshes from Google, at most once a day.
    ///
    /// Silent about everything. A missing grant, a quota, a network that is
    /// not there -- all of them mean the same thing to the person looking at
    /// the screen, which is that they see letters rather than faces, exactly
    /// as they did before.
    func refresh(accessToken: String) async {
        guard !isFetching else { return }
        if let fetched = Self.fetchedAt, Date.now.timeIntervalSince(fetched) < Self.maxAge {
            return
        }

        isFetching = true
        defer { isFetching = false }

        var found: [String: URL] = [:]
        var pageToken: String?
        var pages = 0

        repeat {
            guard let page = await Self.connections(accessToken: accessToken, pageToken: pageToken)
            else { break }

            for person in page.connections ?? [] {
                // 🔴 `default: true` is Google's grey silhouette, not a
                // photograph. Taking it would give every contact without a
                // picture the *same* generic face -- worse than a letter,
                // which is at least their own initial, and exactly the failure
                // `BrandIcon` documents for its own placeholder.
                guard let photo = (person.photos ?? []).first(where: { $0.default != true }),
                      let url = URL(string: photo.url)
                else { continue }

                for entry in person.emailAddresses ?? [] {
                    let address = entry.value.lowercased()
                    guard !address.isEmpty else { continue }
                    found[address] = url
                }
            }

            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < Self.maxPages

        guard !found.isEmpty else { return }

        photos = found
        loaded = true
        save()
        generation &+= 1
    }

    /// Everything goes when the account does.
    func forgetAll() {
        photos = [:]
        loaded = true
        if let url = Self.file {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Google

    private struct Page: Decodable {
        var connections: [Person]?
        var nextPageToken: String?
    }

    private struct Person: Decodable {
        var emailAddresses: [Email]?
        var photos: [Photo]?

        struct Email: Decodable { var value: String }
        struct Photo: Decodable {
            var url: String
            /// Google's own word for "this is the silhouette, not a face".
            var `default`: Bool?
        }
    }

    private static func connections(accessToken: String, pageToken: String?) async -> Page? {
        var components = URLComponents(
            string: "https://people.googleapis.com/v1/people/me/connections"
        )
        components?.queryItems = [
            URLQueryItem(name: "personFields", value: "emailAddresses,photos"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortOrder", value: "LAST_MODIFIED_DESCENDING"),
        ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }

        return try? JSONDecoder().decode(Page.self, from: data)
    }

    // MARK: - Disk

    /// Account-wide rather than per mailbox. Contacts belong to the person,
    /// and two Google accounts on one phone usually know most of the same
    /// people -- keeping two copies would mean two fetches to draw the same
    /// faces.
    private static var file: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }

        let folder = base.appendingPathComponent("Maily", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("contacts.json")
    }

    private static var fetchedAt: Date? {
        guard let url = file,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private func load() {
        loaded = true
        guard let url = Self.file,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: URL].self, from: data)
        else { return }
        photos = stored
    }

    private func save() {
        guard let url = Self.file,
              let data = try? JSONEncoder().encode(photos)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
