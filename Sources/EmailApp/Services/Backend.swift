import Foundation
import Supabase

/// Rows in Supabase, over PostgREST.
///
/// Hand-rolled over URLSession for the same reason `AIService` is: the wire
/// shape stays visible instead of behind the SDK's generics, and there are
/// only four verbs here.
///
/// Everything is scoped by Row Level Security on the server, keyed to the
/// signed-in user. Nothing here passes a user id up as a filter and trusts
/// it; the database decides what this token can see. That matters because
/// the anon key ships in the binary and is therefore public.
enum Backend {

    /// Nobody is signed in, so there is nothing to sync to. Not an error:
    /// the app works signed out, it just keeps everything on the phone.
    struct SignedOut: Error {}

    // MARK: - Verbs

    static func select<T: Decodable>(_ table: String, query: String = "") async throws -> [T] {
        let suffix = query.isEmpty ? "select=*" : query
        let (data, _) = try await send(
            "GET", table, query: suffix, body: nil, prefer: nil
        )
        return try decoder.decode([T].self, from: data)
    }

    /// Insert, or overwrite the row that already has this primary key.
    static func upsert<T: Encodable>(_ table: String, _ rows: [T]) async throws {
        guard !rows.isEmpty else { return }
        _ = try await send(
            "POST", table,
            query: "",
            body: try encoder.encode(rows),
            prefer: "resolution=merge-duplicates,return=minimal"
        )
    }

    static func delete(_ table: String, id: UUID) async throws {
        _ = try await send(
            "DELETE", table, query: "id=eq.\(id.uuidString.lowercased())",
            body: nil, prefer: "return=minimal"
        )
    }

    /// Everything of this person's, in one table.
    ///
    /// Only for signing out of Maily altogether. Removing *a mailbox* must
    /// use `deleteAll(_:mailbox:)` -- this used to be called for that, which
    /// meant disconnecting one account wiped every conversation and every
    /// saved search the person had, on every device.
    static func deleteAll(_ table: String) async throws {
        let id = try await userID()
        _ = try await send(
            "DELETE", table, query: "user_id=eq.\(id.uuidString.lowercased())",
            body: nil, prefer: "return=minimal"
        )
    }

    /// Everything belonging to one mailbox. What the phone forgets when a
    /// mailbox goes, the server forgets too -- and nothing else does.
    static func deleteAll(_ table: String, mailbox: MailboxID) async throws {
        let id = try await userID()
        _ = try await send(
            "DELETE", table,
            query: "user_id=eq.\(id.uuidString.lowercased())&mailbox_id=eq.\(mailbox.rawValue)",
            body: nil, prefer: "return=minimal"
        )
    }

    // MARK: - Who is asking

    /// The signed-in user's id, for the `user_id` column. RLS checks it
    /// again on the server, so this is a convenience and not the guard.
    static func userID() async throws -> UUID {
        guard let session = try? await SupabaseClient.shared.auth.session else {
            throw SignedOut()
        }
        return session.user.id
    }

    static var isSignedIn: Bool {
        get async { (try? await SupabaseClient.shared.auth.session) != nil }
    }

    // MARK: - Transport

    private static func send(
        _ method: String,
        _ table: String,
        query: String,
        body: Data?,
        prefer: String?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let session = try? await SupabaseClient.shared.auth.session else {
            throw SignedOut()
        }

        var url = SupabaseConfig.url.appending(path: "rest/v1/\(table)")
        if !query.isEmpty {
            url = URL(string: url.absoluteString + "?" + query) ?? url
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            // PostgREST reports its own failures as { "message": "..." }.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw BackendError.server(message ?? "The server returned \(http.statusCode).")
        }
        return (data, http)
    }

    enum BackendError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self { case .server(let message): message }
        }
    }

    // MARK: - Coding

    /// Postgres hands back `timestamptz` as ISO 8601, sometimes with
    /// fractional seconds and sometimes without. `.iso8601` alone rejects the
    /// first kind, which is the kind Supabase actually sends.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: text) ?? plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Not an ISO 8601 date: \(text)"
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()
}
