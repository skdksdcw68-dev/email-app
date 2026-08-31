import Foundation

extension String {
    /// Removes CSS and JSON-LD that survive tag stripping.
    ///
    /// Stripping `<style>` blocks handles well-formed mail. Plenty of bulk
    /// senders are not well-formed: they put stylesheets in the plain-text
    /// alternative, or declare the part as text/plain and fill it with markup,
    /// or wrap rules in conditional comments that never match the pattern.
    /// The result is an email that opens as a wall of `-webkit-text-size-adjust`
    /// with the actual message buried somewhere in the middle.
    ///
    /// So this is a second pass over the *text*, after all markup handling:
    /// anything shaped like a CSS rule or a JSON-LD object goes, and what is
    /// left is what a person wrote.
    func removingStrayMarkup() -> String {
        var text = self

        // JSON-LD blocks, which senders embed for inbox actions. Matched by
        // shape rather than by tag, since the tag is usually already gone.
        text = text.replacingOccurrences(
            of: "\\{\\s*\"@context\"[\\s\\S]*?\\n\\s*\\}",
            with: " ",
            options: .regularExpression
        )

        // At-rules with a body: @media, @supports, @font-face.
        text = text.replacingOccurrences(
            of: "@(media|supports|font-face|import|charset)[^{]*\\{[\\s\\S]*?\\}\\s*\\}?",
            with: " ",
            options: .regularExpression
        )

        // Ordinary rules: a selector, then a brace block containing at least
        // one `property: value;`. Requiring the colon and semicolon is what
        // keeps this from eating prose that happens to contain braces.
        text = text.replacingOccurrences(
            of: "[^{}\\n]{1,120}\\{[^{}]*[a-zA-Z-]+\\s*:[^{}]*;[^{}]*\\}",
            with: " ",
            options: .regularExpression
        )

        // Leftover declarations outside any block, which is what a half-parsed
        // stylesheet degrades into.
        text = text.replacingOccurrences(
            of: "(?m)^\\s*-?[a-zA-Z-]{2,40}\\s*:\\s*[^;\\n]{1,80};\\s*$",
            with: "",
            options: .regularExpression
        )

        return text
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(\\s*\\n\\s*){3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this reads as markup rather than as a message.
    ///
    /// Used to decide that a part Gmail labelled text/plain is nothing of the
    /// sort, and should go through the HTML path instead.
    var looksLikeMarkup: Bool {
        let sample = prefix(600).lowercased()
        let markers = [
            "<!doctype", "<html", "<table", "<div", "text-size-adjust",
            "mso-line-height-rule", "!important", "@media",
        ]
        return markers.contains { sample.contains($0) }
    }
}
