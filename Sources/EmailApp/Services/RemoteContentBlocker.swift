import Foundation
import WebKit

/// Stops an email fetching anything from its sender's servers until asked.
///
/// A message is HTML, and HTML can ask for pictures, stylesheets and fonts
/// from anywhere. A one-pixel image nobody can see is the standard way to
/// learn that an address is real, when it was read, how often, roughly from
/// where, and on what -- with no click and no consent. Gmail answers this by
/// proxying every image through Google; Maily answers it by not fetching
/// anything until the person says so.
///
/// A `WKContentRuleList` rather than rewriting the HTML: it is enforced by
/// WebKit itself, below anything the message can express, so a background
/// image in a style attribute or a font in an `@import` is caught by the same
/// rule as an `<img>`. Rewriting HTML with a regular expression catches the
/// cases you thought of.
///
/// ⚠️ `document` is deliberately not blocked. Those are navigations -- link
/// taps -- and `HTMLMessageView` decides those itself.
@MainActor
enum RemoteContentBlocker {

    /// http and https only. `cid:` (an image carried inside the message) and
    /// `data:` (one inlined into it) are part of the mail, arrive with it,
    /// and tell the sender nothing.
    private static let rules = """
    [{
      "trigger": {
        "url-filter": "^https?://",
        "resource-type": ["image", "style-sheet", "font", "media", "raw", "script", "svg-document"]
      },
      "action": { "type": "block" }
    }]
    """

    private static let identifier = "maily.blockRemoteContent.v1"

    private static var compiled: WKContentRuleList?
    /// One compile shared by every message, and by every caller that arrives
    /// while the first is still running.
    private static var work: Task<WKContentRuleList?, Never>?

    /// The list, compiled on first use.
    ///
    /// Nil means WebKit would not compile it, which is not a reason to load
    /// the pictures anyway -- `HTMLMessageView` strips them from the HTML
    /// instead. There is no path here that ends in "fetch it and hope".
    static func list() async -> WKContentRuleList? {
        if let compiled { return compiled }
        if let work { return await work.value }

        let task = Task<WKContentRuleList?, Never> {
            let store = WKContentRuleListStore.default()
            let list: WKContentRuleList? = await withCheckedContinuation { continuation in
                store?.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: rules
                ) { list, error in
                    if let error { print("content rule list: \(error)") }
                    continuation.resume(returning: list)
                }
            }
            compiled = list
            return list
        }
        work = task
        return await task.value
    }

    /// Prepared at launch so the first message opened does not wait for a
    /// compile before it can be shown.
    static func prepare() { Task { _ = await list() } }
}

// MARK: - What a message would fetch

extension HTMLMessageView {

    /// Whether this message asks for anything from the network.
    ///
    /// Used only to decide whether the "images not loaded" line is worth
    /// showing. A plain message, or one whose pictures came inlined, must not
    /// carry a notice about something that was never going to happen.
    nonisolated static func wantsRemoteContent(_ html: String) -> Bool {
        let patterns = [
            #"<img[^>]+src\s*=\s*["']?https?://"#,
            #"url\(\s*["']?https?://"#,
            #"<link[^>]+href\s*=\s*["']?https?://"#,
            #"background\s*=\s*["']?https?://"#,
        ]
        return patterns.contains {
            html.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The fallback, for the case where WebKit would not give us a rule list.
    ///
    /// Blunt on purpose: an `<img>` pointing at a sender's server becomes an
    /// `<img>` pointing at nothing. It mangles the layout of a designed
    /// email, and that is the right trade against fetching it silently.
    nonisolated static func strippingRemoteContent(_ html: String) -> String {
        var stripped = html
        let replacements: [(String, String)] = [
            (#"(<img[^>]+src\s*=\s*["']?)https?://[^"'\s>]*"#, "$1"),
            (#"(<link[^>]+href\s*=\s*["']?)https?://[^"'\s>]*"#, "$1"),
            (#"url\(\s*["']?https?://[^)]*\)"#, "url()"),
            (#"(background\s*=\s*["']?)https?://[^"'\s>]*"#, "$1"),
        ]
        for (pattern, template) in replacements {
            stripped = stripped.replacingOccurrences(
                of: pattern,
                with: template,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return stripped
    }
}
