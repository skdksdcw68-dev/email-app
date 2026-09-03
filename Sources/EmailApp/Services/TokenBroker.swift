import Foundation

/// Access tokens, one mailbox at a time.
///
/// **Why the app owns this instead of the SDK.** GoogleSignIn keeps exactly
/// one session: `GIDSignIn.sharedInstance.currentUser` is a singleton, signing
/// in a second account *replaces* the first, and `restorePreviousSignIn()`
/// brings back one at a cold launch. Holding a `GIDGoogleUser` per account
/// works inside a single run and falls apart the moment the app is killed --
/// every other mailbox would need an interactive consent screen on every
/// launch, which is not a product.
///
/// So GoogleSignIn stays as the consent UI, the refresh token it produces is
/// kept in the Keychain under the mailbox id, and everything after that is a
/// form POST. The same shape serves Microsoft later, and IMAP has no SDK to
/// lose in the first place -- one credential path for three providers rather
/// than three.
///
/// An actor because the cache is shared and every screen asks it questions.
actor TokenBroker {
    static let shared = TokenBroker()

    private struct Token {
        let value: String
        let expires: Date
    }

    private var cache: [MailboxID: Token] = [:]

    /// Refreshes already running, keyed by mailbox.
    ///
    /// Not an optimisation -- a correctness requirement. `fetchInbox` fans out
    /// twenty-five concurrent message reads, and each one asks for a token.
    /// The SDK used to coalesce that for free; owning the refresh means owning
    /// the coalescing too, or the first page of every import fires twenty-five
    /// simultaneous token requests and Google starts refusing them.
    private var inFlight: [MailboxID: Task<Token, Error>] = [:]

    /// Refresh this far before expiry. A token that dies mid-request is a
    /// failed request, and a minute costs nothing.
    private static let margin: TimeInterval = 60

    // MARK: - Asking

    func accessToken(for account: MailAccount) async throws -> String {
        if let held = cache[account.id], held.expires > Date.now.addingTimeInterval(Self.margin) {
            return held.value
        }

        if let running = inFlight[account.id] {
            return try await running.value
        }

        let task = Task<Token, Error> { try await Self.obtain(for: account) }
        inFlight[account.id] = task

        do {
            let fresh = try await task.value
            inFlight[account.id] = nil
            cache[account.id] = fresh
            return fresh.value
        } catch {
            inFlight[account.id] = nil
            throw error
        }
    }

    /// Throws away what is held without touching the stored credential. For
    /// the case where a request comes back 401 on a token this thinks is
    /// still good.
    func invalidate(_ id: MailboxID) {
        cache[id] = nil
    }

    /// Ends the grant at Google, not just here.
    ///
    /// `GIDSignIn.signOut()` only forgets locally, which is why disconnecting
    /// a mailbox used to leave a working token behind. This actually revokes.
    func revoke(_ account: MailAccount) async {
        cache[account.id] = nil
        defer { Keychain.deleteAll(for: account.id) }

        guard account.provider == .gmail,
              let refresh = Keychain.read(.refreshToken, for: account.id),
              let url = URL(string: "https://oauth2.googleapis.com/revoke")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("token=\(refresh)".utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Getting one

    private static func obtain(for account: MailAccount) async throws -> Token {
        guard account.provider == .gmail else {
            // Microsoft and IMAP arrive with their own stages. Until then this
            // is honest about not being able to serve them.
            throw TokenError.unsupported(account.provider)
        }

        if let refresh = Keychain.read(.refreshToken, for: account.id) {
            return try await exchange(refresh: refresh)
        }

        // Nothing stored: this mailbox was connected by a build that let the
        // SDK keep the credential. The SDK still has it, so take a token from
        // there this once and save the refresh token for every time after.
        //
        // Without this every existing install is signed out by the upgrade.
        guard let adopted = await AuthService.adoptSDKCredential(for: account) else {
            throw TokenError.noCredential
        }
        Keychain.storeQuietly(adopted.refreshToken, .refreshToken, for: account.id)
        return Token(value: adopted.accessToken, expires: adopted.expires)
    }

    /// The refresh grant. An installed app has no client secret, so this is a
    /// plain form POST with the client id from Info.plist.
    private static func exchange(refresh: String) async throws -> Token {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              let url = URL(string: "https://oauth2.googleapis.com/token")
        else { throw TokenError.noCredential }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            [
                "client_id=\(clientID)",
                "refresh_token=\(refresh)",
                "grant_type=refresh_token",
            ].joined(separator: "&").utf8
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = payload["error"] as? String ?? "unknown"
            // The grant is gone: revoked in Google's account settings, or the
            // password changed. Told apart from a network blip because the
            // answer is different -- this one needs a person, not a retry.
            if code == "invalid_grant" {
                throw TokenError.revoked(payload["error_description"] as? String ?? code)
            }
            throw TokenError.provider(code)
        }

        guard let token = payload["access_token"] as? String else {
            throw TokenError.provider("no access_token in the reply")
        }
        let seconds = payload["expires_in"] as? Double ?? 3000
        return Token(value: token, expires: .now.addingTimeInterval(seconds))
    }
}

enum TokenError: LocalizedError, Equatable {
    /// Nothing stored, and the SDK had nothing to adopt either.
    case noCredential
    /// Google says the grant is finished. Needs signing in again; retrying
    /// will never work.
    case revoked(String)
    case provider(String)
    case unsupported(MailProvider)

    var errorDescription: String? {
        switch self {
        case .noCredential:
            "This mailbox needs connecting again."
        case .revoked(let why):
            "Google ended the connection to this mailbox. \(why)"
        case .provider(let why):
            "Google refused the sign-in. \(why)"
        case .unsupported(let provider):
            "\(provider.title) mailboxes are not connected yet."
        }
    }

    /// Whether asking again could ever help.
    var needsReauth: Bool {
        switch self {
        case .revoked, .noCredential: true
        case .provider, .unsupported: false
        }
    }
}

extension Keychain {
    /// Storing a credential is not something a caller can do anything about
    /// when it fails, and the fallback is the same either way: ask again next
    /// time. So the throw is swallowed here rather than at twelve call sites.
    static func storeQuietly(_ value: String, _ kind: Secret, for id: MailboxID) {
        try? store(value, kind, for: id)
    }
}
