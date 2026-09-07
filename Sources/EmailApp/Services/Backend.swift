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

    /// Calls a Postgres function.
    ///
    /// For the things a client may ask but must not be able to *parameterise*
    /// -- `my_spend()` reads `auth.uid()` itself, so there is no user id to
    /// pass and therefore no way to ask about somebody else. A table or view
    /// could not express that; a `security definer` function can.
    ///
    /// A `returns table` function answers with an array of rows, which is why
    /// this decodes a collection even when there is only ever one.
    static func rpc<T: Decodable>(
        _ function: String,
        arguments: [String: String] = [:]
    ) async throws -> [T] {
        let body = try JSONSerialization.data(withJSONObject: arguments)
        let (data, _) = try await send(
            "POST", "rpc/\(function)", query: "", body: body, prefer: nil
        )
        return try decoder.decode([T].self, from: data)
    }

    /// Insert, or overwrite the row that already has this primary key.
    /// `onConflict` names the columns that decide whether a row is the same
    /// row. Without it PostgREST resolves on the primary key, which is right
    /// until a table gains a composite one — `devices` is keyed on
    /// (token, address) now, and merging on the token alone made a second
    /// mailbox overwrite the first rather than join it.
    static func upsert<T: Encodable>(
        _ table: String,
        _ rows: [T],
        onConflict: String? = nil
    ) async throws {
        guard !rows.isEmpty else { return }
        _ = try await send(
            "POST", table,
            query: onConflict.map { "on_conflict=\($0)" } ?? "",
            body: try encoder.encode(rows),
            prefer: "resolution=merge-duplicates,return=minimal"
        )
    }

    /// One device's row for one mailbox.
    ///
    /// By the pair, deliberately. Deleting by token alone would unsubscribe
    /// the phone from every mailbox to remove one, and deleting by address
    /// alone would unsubscribe every one of this person's phones.
    static func deleteDevice(token: String, address: String) async throws {
        _ = try await send(
            "DELETE", "devices",
            query: "token=eq.\(token)&address=eq.\(address)",
            body: nil, prefer: "return=minimal"
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
            // PostgREST reports its own failures as { "message": "..." }, and
            // those are written for whoever wrote the SQL: "duplicate key
            // value violates unique constraint \"user_settings_pkey\"". Kept
            // for the console, never shown -- `errorDescription` answers from
            // the status instead.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw BackendError.server(status: http.statusCode, detail: message)
        }
        return (data, http)
    }

    // MARK: - Ending an account

    /// Deletes the account and everything keyed to it, on the server.
    ///
    /// App Store guideline 5.1.1(v): an app that creates accounts must delete
    /// them from inside the app. Signing out is not deleting, and "write to
    /// support" is not either -- both were all Maily had.
    ///
    /// Deliberately *not* built on `deleteAll` below. That deletes one table
    /// through PostgREST as the signed-in user, which cannot touch the auth
    /// record itself and would leave the login standing with its data gone.
    /// The `account` edge function holds the service role, removes the rows
    /// and the login in one pass, and refuses outright if the caller's token
    /// does not verify.
    ///
    /// Throws rather than reporting success quietly. A screen that says
    /// "deleted" over an account that still exists is worse than an error.
    static func deleteAccount() async throws {
        guard let session = try? await SupabaseClient.shared.auth.session else {
            throw BackendError.server(status: 401, detail: "no session")
        }

        var request = URLRequest(url: SupabaseConfig.url.appending(path: "functions/v1/account"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "delete"])
        // Longer than the usual 20: this is nine deletes and an admin call,
        // and it is the one request nobody wants retried by hand.
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            // The `account` function's failures are written for the person --
            // "your data is deleted but the sign-in could not be removed" is
            // something they need to read, and no status code says it.
            if let message, !message.isEmpty { throw BackendError.explained(message) }
            throw BackendError.server(status: http.statusCode, detail: nil)
        }
    }

    enum BackendError: LocalizedError {
        case server(status: Int, detail: String?)
        /// A failure the server described in words meant to be read.
        case explained(String)

        var errorDescription: String? {
            switch self {
            case .explained(let message): message
            case .server(let status, _):
                switch status {
                case 401, 403: "You've been signed out. Sign in again."
                case 404: "That isn't there any more."
                case 409: "That is already saved."
                case 413: "That was too big to save."
                case 429: "Too much at once. Give it a moment and try again."
                case 500...599: "Maily's server is having trouble. Try again shortly."
                default: "Maily couldn't save that just now. Try again."
                }
            }
        }

        /// What the server actually said, for a log. Never for a screen.
        var detail: String? {
            switch self {
            case .server(_, let detail): detail
            case .explained(let message): message
            }
        }
    }

    // MARK: - Coding

    // A fresh one per call, rather than four shared instances.
    //
    // These are reached from every `Task.detached` in the app -- analytics,
    // chat sync, search sync, memory sync, push registration -- so several
    // threads can be inside one at once. Neither `JSONDecoder` nor
    // `ISO8601DateFormatter` is documented thread-safe, and the failure mode
    // is not an error, it is a corrupted heap detected somewhere unrelated
    // half a minute later. `AIUsage` cost a crash learning that.
    //
    // Making them computed costs an allocation per request, next to a network
    // round trip. That is not a trade worth thinking about.

    /// Postgres hands back `timestamptz` as ISO 8601, sometimes with
    /// fractional seconds and sometimes without. `.iso8601` alone rejects the
    /// first kind, which is the kind Supabase actually sends.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Built here, inside the closure, so each decode has its own.
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Not an ISO 8601 date: \(text)"
            )
        }
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
