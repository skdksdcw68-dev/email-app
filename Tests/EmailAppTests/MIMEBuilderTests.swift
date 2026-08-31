import XCTest
@testable import EmailApp

/// The message Gmail actually receives. Everything here is pure string
/// building, so it can be checked exactly -- which matters, because a wrong
/// byte in the encoding fails as a 400 that does not say what was wrong.
final class MIMEBuilderTests: XCTestCase {

    private func envelope(
        subject: String = "Hello",
        plain: String = "Hi there",
        html: String? = nil,
        cc: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> MIMEBuilder.Envelope {
        MIMEBuilder.Envelope(
            from: "Abel <abel@example.com>",
            to: "sara@example.com",
            cc: cc,
            subject: subject,
            plainText: plain,
            html: html,
            inReplyTo: inReplyTo,
            references: references
        )
    }

    private func decodedBody(_ message: String) -> String {
        // Everything after the blank line that ends the headers.
        guard let range = message.range(of: "\r\n\r\n") else { return "" }
        let encoded = message[range.upperBound...]
            .replacingOccurrences(of: "\r\n", with: "")
        guard let data = Data(base64Encoded: encoded) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Headers

    func testCarriesTheBasicHeaders() {
        let message = MIMEBuilder.message(envelope())
        XCTAssertTrue(message.contains("From: Abel <abel@example.com>"))
        XCTAssertTrue(message.contains("To: sara@example.com"))
        XCTAssertTrue(message.contains("Subject: Hello"))
        XCTAssertTrue(message.contains("MIME-Version: 1.0"))
    }

    func testCcIsOmittedWhenEmpty() {
        XCTAssertFalse(MIMEBuilder.message(envelope()).contains("Cc:"))
        XCTAssertFalse(MIMEBuilder.message(envelope(cc: "")).contains("Cc:"))
        XCTAssertTrue(MIMEBuilder.message(envelope(cc: "x@y.com")).contains("Cc: x@y.com"))
    }

    func testUsesCRLFLineEndings() {
        // RFC 2822 is CRLF. Gmail tolerates bare LF; other hops in the chain
        // do not, and the failure is silent corruption rather than an error.
        let message = MIMEBuilder.message(envelope())
        XCTAssertTrue(message.contains("\r\n"))
        XCTAssertFalse(message.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    // MARK: - Subject encoding

    func testAsciiSubjectIsLeftAlone() {
        XCTAssertEqual(MIMEBuilder.encodedHeader("Launch decision"), "Launch decision")
    }

    func testNonAsciiSubjectIsEncodedWord() {
        let encoded = MIMEBuilder.encodedHeader("Café ☕")
        XCTAssertTrue(encoded.hasPrefix("=?UTF-8?B?"))
        XCTAssertTrue(encoded.hasSuffix("?="))

        // And it round-trips.
        let base64 = encoded
            .replacingOccurrences(of: "=?UTF-8?B?", with: "")
            .replacingOccurrences(of: "?=", with: "")
        let data = Data(base64Encoded: base64)
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "Café ☕")
    }

    func testNewlinesAreStrippedFromHeaders() {
        // A newline in a header value is header injection: everything after it
        // is parsed as a new header, so a subject could forge a Bcc.
        let encoded = MIMEBuilder.encodedHeader("Hi\r\nBcc: attacker@evil.com")
        XCTAssertFalse(encoded.contains("\r"))
        XCTAssertFalse(encoded.contains("\n"))
    }

    // MARK: - Body

    func testPlainBodyRoundTrips() {
        let body = "Thanks for the update.\n\nThat works for me."
        let message = MIMEBuilder.message(envelope(plain: body))
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=\"UTF-8\""))
        XCTAssertTrue(message.contains("Content-Transfer-Encoding: base64"))
        XCTAssertEqual(decodedBody(message), body)
    }

    func testEmojiSurvivesTheRoundTrip() {
        let body = "Sounds good 😊 see you Thursday"
        XCTAssertEqual(decodedBody(MIMEBuilder.message(envelope(plain: body))), body)
    }

    func testBase64IsWrappedAt76Characters() {
        let long = String(repeating: "a", length: 500)
        let encoded = MIMEBuilder.base64Body(long)
        for line in encoded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
    }

    // MARK: - Multipart

    func testHtmlProducesMultipartAlternative() {
        let message = MIMEBuilder.message(
            envelope(plain: "Hi there", html: "<p><b>Hi</b> there</p>"),
            boundary: "BOUND"
        )
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary=\"BOUND\""))
        XCTAssertTrue(message.contains("--BOUND"))
        XCTAssertTrue(message.contains("Content-Type: text/html; charset=\"UTF-8\""))
        // The closing delimiter needs the trailing dashes or the final part is
        // unterminated and some clients drop it.
        XCTAssertTrue(message.contains("--BOUND--"))
    }

    func testPlainPartComesBeforeHtml() {
        // multipart/alternative is least-rich first; a client picks the last
        // part it understands. Reversed, everyone would see the plain text.
        let message = MIMEBuilder.message(
            envelope(plain: "Hi", html: "<p>Hi</p>"), boundary: "B"
        )
        let plainAt = message.range(of: "text/plain")!.lowerBound
        let htmlAt = message.range(of: "text/html")!.lowerBound
        XCTAssertLessThan(plainAt, htmlAt)
    }

    func testNoMultipartWhenHtmlIsAbsentOrEmpty() {
        XCTAssertFalse(MIMEBuilder.message(envelope()).contains("multipart"))
        XCTAssertFalse(MIMEBuilder.message(envelope(html: "")).contains("multipart"))
    }

    // MARK: - Threading

    func testReplyHeadersAreSet() {
        let message = MIMEBuilder.message(envelope(inReplyTo: "<abc@mail.gmail.com>"))
        XCTAssertTrue(message.contains("In-Reply-To: <abc@mail.gmail.com>"))
        // References falls back to In-Reply-To, which is correct for the first
        // reply in a thread.
        XCTAssertTrue(message.contains("References: <abc@mail.gmail.com>"))
    }

    func testExplicitReferencesWins() {
        let message = MIMEBuilder.message(
            envelope(inReplyTo: "<b@x>", references: "<a@x> <b@x>")
        )
        XCTAssertTrue(message.contains("References: <a@x> <b@x>"))
    }

    func testNoThreadingHeadersOnANewMessage() {
        let message = MIMEBuilder.message(envelope())
        XCTAssertFalse(message.contains("In-Reply-To"))
        XCTAssertFalse(message.contains("References"))
    }

    // MARK: - base64url

    func testRawIsBase64urlWithNoPadding() {
        let raw = MIMEBuilder.raw(envelope())
        XCTAssertFalse(raw.contains("+"))
        XCTAssertFalse(raw.contains("/"))
        XCTAssertFalse(raw.contains("="))
    }

    func testRawDecodesBackToTheMessage() {
        let env = envelope(subject: "Café ☕", plain: "Hi 😊")
        let raw = MIMEBuilder.raw(env, boundary: "B")

        // Undo base64url, restoring padding.
        var standard = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }

        let data = Data(base64Encoded: standard)
        let decoded = data.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(decoded, MIMEBuilder.message(env, boundary: "B"))
    }

    // MARK: - Address formatting

    func testAddressWithAName() {
        XCTAssertEqual(
            MIMEBuilder.address(name: "Abel Amare", email: "abel@x.com"),
            "Abel Amare <abel@x.com>"
        )
    }

    func testAddressWithoutAUsefulName() {
        XCTAssertEqual(MIMEBuilder.address(name: "", email: "abel@x.com"), "abel@x.com")
        XCTAssertEqual(MIMEBuilder.address(name: "   ", email: "abel@x.com"), "abel@x.com")
        XCTAssertEqual(
            MIMEBuilder.address(name: "abel@x.com", email: "abel@x.com"),
            "abel@x.com"
        )
    }

    func testNameWithACommaIsQuoted() {
        // Unquoted, "Amare, Abel" parses as two recipients.
        XCTAssertEqual(
            MIMEBuilder.address(name: "Amare, Abel", email: "abel@x.com"),
            "\"Amare, Abel\" <abel@x.com>"
        )
    }
}

private extension String {
    init(repeating character: String, length: Int) {
        self = String(repeating: character, count: length)
    }
}
