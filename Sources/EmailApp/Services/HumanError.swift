import Foundation

/// Turns whatever went wrong into something a person can act on.
///
/// 🔴 The app had 35 places doing `error.localizedDescription` straight into
/// a label. That is Apple's sentence, or Google's, or Supabase's, and it is
/// written for whoever is holding the stack trace: "The operation couldn't be
/// completed. (NSURLErrorDomain error -1009.)", "AuthApiError: Invalid login
/// credentials", "Gmail returned 401. {\"error\": ...}". Abel signed in with
/// Apple and was told to "sign up first" by a string Supabase wrote for a
/// server log.
///
/// Three rules here:
///
/// 1. Say what happened in words about *mail*, not about HTTP.
/// 2. Say what to do next, when there is something to do.
/// 3. Never show a code, a domain, a status or a JSON body. If nothing better
///    is known, the generic sentence is more honest than a number that means
///    nothing to the person reading it.
enum HumanError {

    /// When nothing more specific is known. Deliberately not "unknown error":
    /// that tells somebody they have hit something nobody understands, which
    /// is frightening and almost never true.
    static let generic = "Something went wrong. Try again."

    static func text(for error: Error) -> String {
        if isCancellation(error) { return "Cancelled." }
        if let url = error as? URLError { return network(url) }
        // A body that did not parse. Common when a proxy or a captive portal
        // answers instead of the real server.
        if error is DecodingError {
            return "Maily got an answer it didn't understand. Try again in a moment."
        }

        // ⚠️ `localizedDescription`, and the only place in the app allowed to
        // say it. `.readable` here would call straight back into this
        // function.
        let raw = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let known = phrase(for: raw) { return known }
        return presentable(raw) ?? generic
    }

    // MARK: - Cancellation

    /// Backing out of a sign-in sheet is not a failure and must never be
    /// shown as one. Every SDK spells it differently.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        // Google Sign-In, ASWebAuthenticationSession, Sign in with Apple.
        if nsError.domain.contains("GIDSignIn"), nsError.code == -5 { return true }
        if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession",
           nsError.code == 1 { return true }
        if nsError.domain == "com.apple.AuthenticationServices.AuthorizationError",
           nsError.code == 1001 { return true }
        return false
    }

    // MARK: - The network

    private static func network(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed:
            "You're offline. Maily will pick this up when you're back."
        case .timedOut:
            "That took too long. Try again."
        case .networkConnectionLost:
            "The connection dropped. Try again."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            "Maily couldn't reach the server. Check your connection and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            "The connection wasn't private, so Maily stopped. Try again on a different network."
        case .internationalRoamingOff:
            "Roaming is off, so Maily can't reach the internet."
        case .callIsActive:
            "A call is using the connection. Try again when it ends."
        case .resourceUnavailable, .badServerResponse, .cannotParseResponse:
            "The server answered with something Maily couldn't use. Try again."
        default:
            "Something went wrong with the connection. Try again."
        }
    }

    // MARK: - The phrasebook

    /// What other people's error text means, in Maily's words.
    ///
    /// Matched on the message rather than the error type on purpose: these
    /// come from Supabase, Google and Apple, whose error *types* change
    /// between SDK versions while these strings do not, and a wrong match
    /// costs a slightly-off sentence rather than a crash.
    private static let phrasebook: [(needle: String, human: String)] = [
        // Supabase Auth -- email and password.
        ("invalid login credentials",
         "That email and password don't match. Check them and try again."),
        ("already registered",
         "There's already an account with that email. Sign in instead."),
        ("user already exists",
         "There's already an account with that email. Sign in instead."),
        ("email not confirmed",
         "Confirm your email first -- check your inbox for the link Maily sent."),
        ("password should be at least",
         "Pick a password with at least 6 characters."),
        ("weak password",
         "That password is too easy to guess. Try a longer one."),
        ("unable to validate email address",
         "That doesn't look like an email address."),
        ("invalid email",
         "That doesn't look like an email address."),
        ("user not found",
         "No Maily account uses that email. Create one to get started."),
        ("signups not allowed", "New accounts are closed right now."),
        ("signup is disabled", "New accounts are closed right now."),
        ("email rate limit", "Too many emails just went out. Wait a minute and try again."),
        ("rate limit", "Too many tries. Wait a minute and try again."),
        ("too many requests", "Too many tries. Wait a minute and try again."),
        ("captcha", "That looked automated to our sign-in provider. Try again."),
        ("session expired", "You've been signed out. Sign in again."),
        ("jwt expired", "You've been signed out. Sign in again."),
        ("refresh token", "You've been signed out. Sign in again."),
        ("invalid claim", "You've been signed out. Sign in again."),

        // Mail servers, both kinds.
        ("authentication failed",
         "The mail server didn't accept that password."),
        ("invalid credentials",
         "The mail server didn't accept that password."),
        ("[alert] please log in",
         "The mail server didn't accept that password."),
        ("application-specific password",
         "This mailbox needs an app password rather than your normal one."),
        ("insufficient permission",
         "Maily doesn't have permission for that. Connect the mailbox again."),
        ("insufficient authentication scopes",
         "Maily doesn't have permission for that. Connect the mailbox again."),
        ("invalid_grant",
         "This mailbox needs connecting again."),
        ("token has been expired or revoked",
         "This mailbox needs connecting again."),
        ("quota", "Your mail provider is asking Maily to slow down. Try again shortly."),

        // Ours, from the edge functions.
        ("no api key", "Maily's AI isn't set up on this account yet."),
        ("insufficient_quota", "Maily's AI ran out of credit. This one is on us to fix."),
        ("context_length_exceeded", "That was too long to work with in one go."),
    ]

    private static func phrase(for raw: String) -> String? {
        let text = raw.lowercased()
        return phrasebook.first { text.contains($0.needle) }?.human
    }

    // MARK: - The last filter

    /// Machine text, whatever it says. Nil means "do not show this".
    ///
    /// Everything that reaches here is a sentence somebody else wrote, and
    /// most of them are fine -- our own `LocalizedError`s land here. These are
    /// the shapes that are never fine.
    private static func presentable(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }

        let machine = [
            "error domain=", "nserror", "nsurlerror", "nslocalized",
            "traceback", "stacktrace", "exception:",
            "<null>", "optional(", "unexpectedly found nil",
        ]
        let lowered = raw.lowercased()
        if machine.contains(where: { lowered.contains($0) }) { return nil }

        // A JSON body, or the head of one.
        if raw.hasPrefix("{") || raw.hasPrefix("[") { return nil }
        // "(NSURLErrorDomain error -1009.)" and friends: a bare negative code
        // in brackets is never for the person reading it.
        if raw.range(of: #"\(\s*-?\d+\s*\)"#, options: .regularExpression) != nil { return nil }
        if raw.range(of: #"error\s+-?\d+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        // Long enough to be a log line, or a wall of a body.
        if raw.count > 220 { return nil }

        // Apple's stock sentence for "no idea", which says nothing at all.
        if lowered.hasPrefix("the operation couldn't be completed") { return nil }
        if lowered == "unknown error" || lowered == "an error occurred" { return nil }

        return raw
    }
}

extension Error {
    /// What to show somebody. Never the raw text an SDK handed over.
    var readable: String { HumanError.text(for: self) }

    /// Backing out of a sheet. Worth checking before showing anything at all.
    var isCancellation: Bool { HumanError.isCancellation(self) }
}
