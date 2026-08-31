import XCTest
@testable import EmailApp

/// What ends up on the second line of a row. Bulk senders put a lot of things
/// in a message body that are not meant to be read.
final class PreviewTextTests: XCTestCase {

    // MARK: - Alt text

    func testImageMarkersAreRemoved() {
        // Senders put [image: Alt Text] in the plain-text alternative wherever
        // the HTML has a picture, so a message that opens with a logo
        // previewed as "[image: Google]" and said nothing at all.
        XCTAssertEqual(
            GmailService.previewText(from: "[image: Google] You allowed Maily access"),
            "You allowed Maily access"
        )
    }

    func testBareImageMarkerIsRemoved() {
        XCTAssertEqual(GmailService.previewText(from: "[image] Hello there"), "Hello there")
    }

    func testCidMarkersAreRemoved() {
        XCTAssertEqual(
            GmailService.previewText(from: "[cid:logo123] Your invoice is ready"),
            "Your invoice is ready"
        )
    }

    // MARK: - Padding

    func testZeroWidthPaddingIsRemoved() {
        // Bulk senders pad with zero-width characters to push their real text
        // out of a client's preview.
        let padded = "\u{200B}\u{200C}\u{FEFF}Real content here"
        XCTAssertEqual(GmailService.previewText(from: padded), "Real content here")
    }

    func testUrlsAreDropped() {
        XCTAssertEqual(
            GmailService.previewText(from: "Click https://example.com/very/long/tracking/url to see"),
            "Click to see"
        )
    }

    func testWhitespaceCollapses() {
        XCTAssertEqual(
            GmailService.previewText(from: "Too   many\n\n  spaces\there"),
            "Too many spaces here"
        )
    }

    // MARK: - HTML stripping

    func testStyleBlockContentIsRemoved() {
        // Stripping only the tags left the CSS behind as body text, which is
        // where "text-decoration: none" was coming from.
        let html = "<style>a { text-decoration: none; color: #fff; }</style><p>Hello</p>"
        let stripped = GmailService.strippingHTML(html)
        XCTAssertFalse(stripped.contains("text-decoration"))
        XCTAssertFalse(stripped.contains("#fff"))
        XCTAssertTrue(stripped.contains("Hello"))
    }

    func testScriptBlockContentIsRemoved() {
        let html = "<script>var x = 1; alert('hi');</script><p>Body</p>"
        let stripped = GmailService.strippingHTML(html)
        XCTAssertFalse(stripped.contains("alert"))
        XCTAssertTrue(stripped.contains("Body"))
    }

    func testHeadContentIsRemoved() {
        let html = "<html><head><title>Ignore me</title></head><body>Read me</body></html>"
        let stripped = GmailService.strippingHTML(html)
        XCTAssertFalse(stripped.contains("Ignore me"))
        XCTAssertTrue(stripped.contains("Read me"))
    }

    func testCommentsAreRemoved() {
        let stripped = GmailService.strippingHTML("<!-- hidden note --><p>Shown</p>")
        XCTAssertFalse(stripped.contains("hidden note"))
        XCTAssertTrue(stripped.contains("Shown"))
    }

    func testEntitiesAreDecoded() {
        XCTAssertEqual(GmailService.strippingHTML("<p>Tom &amp; Jerry&#39;s</p>"), "Tom & Jerry's")
    }

    func testStyleStrippingIsCaseInsensitive() {
        let stripped = GmailService.strippingHTML("<STYLE>p { color: red; }</STYLE><p>Text</p>")
        XCTAssertFalse(stripped.contains("color"))
    }
}
