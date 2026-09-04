import Foundation

/// What a particular mail backend can and cannot do.
///
/// Providers differ in ways the screens have to know about, and the honest
/// way to handle that is to ask rather than to branch on `provider ==` in
/// twelve places. A UI that reads these can soften — hide a control, fall
/// back to a local search — where one that assumes Gmail simply breaks.
struct BackendCapabilities: Sendable, Equatable {

    /// Whether the server can search, or whether searching means filtering
    /// what is already on the phone.
    ///
    /// Gmail and Graph both can. A small IMAP server may advertise no
    /// `SEARCH` worth using, and the app degrades to what it holds rather
    /// than showing an error nobody can act on.
    var canSearchServerSide = true

    /// Whether a provider-written query string means anything here.
    ///
    /// The model writes Gmail search syntax today -- `from:`, `newer_than:`
    /// -- because that is what the prompt asks for. Gmail understands it,
    /// nothing else does, so a backend that says no gets the structured
    /// query and the raw string is treated as plain words instead.
    var acceptsProviderQuerySyntax = false

    /// Whether drafts live on the server.
    ///
    /// Gmail and Graph keep them, so a draft written here appears on every
    /// other device. IMAP has an APPEND to the Drafts folder, which is close
    /// enough. A provider without one would keep drafts on the phone only,
    /// and the app should say so rather than implying they sync.
    var hasServerDrafts = true

    /// Whether the server can wake the phone on its own. False for IMAP: it
    /// would need a socket held open, which iOS does not allow a backgrounded
    /// app, so freshness there is periodic and best-effort.
    var canPush = true

    /// Whether the provider threads conversations itself, or whether the app
    /// has to group by subject and references.
    var threadsNatively = true

    /// The biggest message this backend will accept, in bytes.
    ///
    /// Not a property of email -- a property of the transport. Gmail's four
    /// megabytes is the ceiling on a JSON request body, not a limit on mail;
    /// Graph allows about three inline and far more through an upload
    /// session; an SMTP server states its own in the EHLO reply and the
    /// answer differs per host. So the compose screen asks the backend rather
    /// than reading a constant that was only ever true for one of them.
    var maxOutboundBytes = 4 * 1024 * 1024

    /// Gmail, as it behaves today. Also the sane default for anything not yet
    /// measured.
    static let gmail = BackendCapabilities(
        canSearchServerSide: true,
        acceptsProviderQuerySyntax: true,
        hasServerDrafts: true,
        canPush: true,
        threadsNatively: true,
        maxOutboundBytes: 4 * 1024 * 1024
    )
}
