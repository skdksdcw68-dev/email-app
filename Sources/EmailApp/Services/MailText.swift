import Foundation

/// Turning what senders actually put in an email into something readable.
///
/// Nothing here is Gmail's, or any provider's -- it is HTML, entities, and
/// the tricks bulk senders play on preview text, all of which arrive the same
/// way through IMAP or Graph. It lived on `GmailService` because that is
/// where the parser was, which meant `Message.preview` reached into a
/// provider service to format a string.
enum MailText {

    /// HTML down to text, entities and all.
    static func strippingHTML(_ html: String) -> String {
        html
            // Style and script blocks first, contents and all. Removing only
            // the tags leaves the CSS behind as body text, which is where
            // "text-decoration: none" was coming from in previews.
            .replacingOccurrences(
                of: "<style[^>]*>[\\s\\S]*?</style>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<script[^>]*>[\\s\\S]*?</script>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<head[^>]*>[\\s\\S]*?</head>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression
            )
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&zwnj;", with: "")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(\\s*\\n\\s*){3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .removingStrayMarkup()
    }

    /// Cleans a body down to something worth showing as a one-line preview.
    ///
    /// Senders put `[image: Some Alt Text]` in the plain-text alternative
    /// wherever the HTML has a picture, so a message that opens with a logo
    /// previews as "[image: Google]" and tells the reader nothing. Same for
    /// the invisible preheader padding bulk senders use to control what shows
    /// in a list.
    static func previewText(from body: String) -> String {
        body
            .replacingOccurrences(
                of: "\\[(image|cid|Image|IMAGE)\\s*:[^\\]]*\\]", with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\[image\\]", with: " ", options: [.regularExpression, .caseInsensitive])
            // Zero-width and non-breaking padding, used by bulk senders to
            // push real text out of the preview.
            .replacingOccurrences(of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00A0}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
