import Foundation
import Observation

/// Photographs of the people who write to you, from Google.
///
/// 🔴 **Mail scopes carry no photograph of a sender.** Gmail's own app shows
/// faces because it can see Google's *people* data, which is a different API
/// and a different permission from reading mail -- so an app with mail access
/// alone has nothing to draw and a coloured letter is the honest answer. This
/// is the other half of that sentence: with the Contacts scopes granted, the
/// photographs exist and can be shown.
///
/// ## Two lists, and which one matters
///
/// - **Saved contacts** (`connections.list`, `contacts.readonly`): the people
///   somebody added themselves. A handful.
/// - **Other contacts** (`otherContacts.list`, `contacts.other.readonly`):
///   the list Google keeps of everyone they have ever written to. This is
///   most of the humans in an inbox.
///
/// 🔴 Other contacts must be asked for **with the Google profile merged in**
/// (`sources=READ_SOURCE_TYPE_PROFILE`). Asked for plainly, every entry
/// carries the grey silhouette and nothing else -- which is how an earlier
/// version of this file concluded the list "carries no photos at all" and
/// gave up on it. With the merge, each entry that is a Google account comes
/// back with that account's own profile photo: the same picture Gmail and
/// Shortwave draw. Measured on 2026-09-06 against a real mailbox: 84 other
/// contacts, 0 photos without the merge, 5 addresses with a real one with it.
///
/// ## What is still not covered
///
/// ⚠️ Senders that are not Google accounts, and Google accounts whose owner
/// never set a photo -- most no-reply and notification addresses. Those keep
/// their brand mark from `BrandIcon` or a letter, which is what Gmail shows
/// for the same rows too (a letter, or its grey silhouette).
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

    /// Google's page size limit for both lists.
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

    /// Refreshes from Google, at most once a day -- unless forced, which is
    /// for the moment somebody grants the permission from Settings and is
    /// looking at the inbox waiting for the faces.
    ///
    /// Silent about everything. A missing grant, a quota, a network that is
    /// not there -- all of them mean the same thing to the person looking at
    /// the screen, which is that they see letters rather than faces, exactly
    /// as they did before.
    func refresh(accessToken: String, force: Bool = false) async {
        guard !isFetching else { return }
        if !force, let fetched = Self.fetchedAt, Date.now.timeIntervalSince(fetched) < Self.maxAge {
            return
        }

        isFetching = true
        defer { isFetching = false }

        var found: [String: URL] = [:]

        for source in Source.allCases {
            var pageToken: String?
            var pages = 0

            repeat {
                guard let page = await Self.fetch(source, accessToken: accessToken, pageToken: pageToken)
                else { break }

                for person in page.people {
                    // 🔴 `default: true` is Google's grey silhouette, not a
                    // photograph. Taking it would give every contact without a
                    // picture the *same* generic face -- worse than a letter,
                    // which is at least their own initial, and exactly the
                    // failure `BrandIcon` documents for its own placeholder.
                    guard let photo = (person.photos ?? []).first(where: { $0.default != true }),
                          let url = Self.sharpened(photo.url)
                    else { continue }

                    for entry in person.emailAddresses ?? [] {
                        let address = entry.value.lowercased()
                        // The first list to answer for an address keeps it;
                        // see `Source` for the order and why.
                        guard !address.isEmpty, found[address] == nil else { continue }
                        found[address] = url
                    }
                }

                pageToken = page.nextPageToken
                pages += 1
            } while pageToken != nil && pages < Self.maxPages
        }

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

    /// The two lists, in the order they are trusted. A photo somebody chose
    /// for a saved contact beats the one the contact chose for themselves, so
    /// saved contacts go first and other contacts only fill the gaps.
    ///
    /// Each list needs its own scope, and a grant may hold one without the
    /// other. A list whose scope is missing answers 403, which `fetch` reads
    /// as an empty list and nothing else.
    private enum Source: CaseIterable {
        case connections, otherContacts

        var endpoint: String {
            switch self {
            case .connections:
                return "https://people.googleapis.com/v1/people/me/connections"
            case .otherContacts:
                return "https://people.googleapis.com/v1/otherContacts"
            }
        }

        var query: [URLQueryItem] {
            switch self {
            case .connections:
                return [
                    URLQueryItem(name: "personFields", value: "emailAddresses,photos"),
                    URLQueryItem(name: "sortOrder", value: "LAST_MODIFIED_DESCENDING"),
                ]
            case .otherContacts:
                return [
                    URLQueryItem(name: "readMask", value: "emailAddresses,photos"),
                    // 🔴 The profile merge. Without PROFILE every entry is a
                    // silhouette; CONTACT has to be named alongside it because
                    // Google refuses PROFILE on its own.
                    URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_CONTACT"),
                    URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_PROFILE"),
                ]
            }
        }
    }

    private struct Page: Decodable {
        var connections: [Person]?
        var otherContacts: [Person]?
        var nextPageToken: String?

        /// Whichever list this is a page of.
        var people: [Person] { connections ?? otherContacts ?? [] }
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

    private static func fetch(_ source: Source, accessToken: String, pageToken: String?) async -> Page? {
        var components = URLComponents(string: source.endpoint)
        components?.queryItems = source.query
            + [URLQueryItem(name: "pageSize", value: String(pageSize))]
            + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }

        return try? JSONDecoder().decode(Page.self, from: data)
    }

    /// Google hands out `=s100`: a 100px thumbnail, soft in a 44pt circle on
    /// a 3x screen. The suffix is a request rather than a fact about the
    /// file -- the same URL answers `=s256-c` with a 256px centre crop.
    ///
    /// `nonisolated`: a pure string function with no business dragging the
    /// main actor into a test.
    nonisolated static func sharpened(_ text: String) -> URL? {
        guard let range = text.range(of: #"=s\d+(-c)?$"#, options: .regularExpression) else {
            return URL(string: text)
        }
        return URL(string: text.replacingCharacters(in: range, with: "=s256-c"))
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
