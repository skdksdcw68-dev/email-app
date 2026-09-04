import XCTest
@testable import EmailApp

/// Gmail's API handed over a parsed tree. IMAP hands over the bytes somebody
/// posted in 2009 from a client nobody maintains, so everything Google was
/// quietly doing has to happen in `MIMEParser` -- and this is the only place
/// it can be checked, because a real server is not available to CI.
final class MIMEParserTests: XCTestCase {

    private func parse(_ raw: String) -> MIMEParser.Parsed {
        MIMEParser.parse(Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    // MARK: - Headers

    func testItReadsTheBasicHeaders() {
        let parsed = parse("""
        From: Ada Lovelace <ada@example.com>
        To: bob@example.com
        Subject: Numbers
        Date: Tue, 15 Nov 1994 12:45:26 +0100

        Hello.
        """)

        XCTAssertEqual(parsed.from?.address, "ada@example.com")
        XCTAssertEqual(parsed.from?.name, "Ada Lovelace")
        XCTAssertEqual(parsed.subject, "Numbers")
        XCTAssertEqual(parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello.")
    }

    func testAFoldedHeaderIsOneValue() {
        // Long subjects arrive wrapped across lines with the continuation
        // indented. Treating the second line as a new header loses half the
        // subject and invents a header called nothing.
        let parsed = parse("""
        Subject: A subject that was too long
         to fit on one line
        From: a@b.com

        body
        """)

        XCTAssertEqual(parsed.subject, "A subject that was too long to fit on one line")
    }

    func testHeaderNamesAreCaseInsensitive() {
        let parsed = parse("""
        SUBJECT: Shouting
        FROM: a@b.com

        body
        """)
        XCTAssertEqual(parsed.subject, "Shouting")
    }

    // MARK: - Encoded words

    func testItDecodesABase64EncodedSubject() {
        let parsed = parse("""
        Subject: =?UTF-8?B?SGVsbG8gd29ybGQ=?=
        From: a@b.com

        body
        """)
        XCTAssertEqual(parsed.subject, "Hello world")
    }

    func testItDecodesAQuotedPrintableSubject() {
        // "_" is a space inside an encoded word, and only there.
        let parsed = parse("""
        Subject: =?UTF-8?Q?Fakt=C3=BCra_2024?=
        From: a@b.com

        body
        """)
        XCTAssertEqual(parsed.subject, "Faktüra 2024")
    }

    func testAdjacentEncodedWordsDoNotGainASpace() {
        // A long encoded subject is split into several words. The whitespace
        // between them is syntax, not text -- keep it and words break in half.
        let parsed = parse("""
        Subject: =?UTF-8?B?SGVsbG8g?= =?UTF-8?B?d29ybGQ=?=
        From: a@b.com

        body
        """)
        XCTAssertEqual(parsed.subject, "Hello world")
    }

    func testTextAroundAnEncodedWordSurvives() {
        let parsed = parse("""
        Subject: Re: =?UTF-8?B?ZsO2cg==?= you
        From: a@b.com

        body
        """)
        XCTAssertEqual(parsed.subject, "Re: för you")
    }

    func testSomethingThatIsNotAnEncodedWordIsLeftAlone() {
        let parsed = parse("""
        Subject: What =? means
        From: a@b.com

        body
        """)
        XCTAssertEqual(parsed.subject, "What =? means")
    }

    // MARK: - Bodies

    func testQuotedPrintableBodyIsDecoded() {
        let parsed = parse("""
        From: a@b.com
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Total: =E2=82=AC50
        """)
        XCTAssertEqual(parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), "Total: €50")
    }

    func testASoftLineBreakJoinsTheLine() {
        // "=" at the end of a line means the break is not really there.
        let parsed = parse("""
        From: a@b.com
        Content-Transfer-Encoding: quoted-printable

        one=
        two
        """)
        XCTAssertEqual(parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), "onetwo")
    }

    func testBase64BodyIsDecoded() {
        let parsed = parse("""
        From: a@b.com
        Content-Transfer-Encoding: base64

        SGVsbG8gZnJvbSBiYXNlNjQ=
        """)
        XCTAssertEqual(parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello from base64")
    }

    func testALatin1BodyIsNotMangled() {
        var data = Data("From: a@b.com\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\n".utf8)
        data.append(contentsOf: [0x43, 0x61, 0x66, 0xE9])  // "Café" in Latin-1
        XCTAssertEqual(
            MIMEParser.parse(data).text?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Café"
        )
    }

    // MARK: - Multipart

    func testAlternativeGivesBothTextAndHTML() {
        let parsed = parse("""
        From: a@b.com
        Content-Type: multipart/alternative; boundary="XYZ"

        --XYZ
        Content-Type: text/plain

        plain version
        --XYZ
        Content-Type: text/html

        <p>rich version</p>
        --XYZ--
        """)

        XCTAssertEqual(parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), "plain version")
        XCTAssertEqual(parsed.html?.trimmingCharacters(in: .whitespacesAndNewlines), "<p>rich version</p>")
    }

    func testAnHTMLOnlyMessageStillHasReadableText() {
        // `body` is what the row preview, the classifier and search all read.
        // Leaving it empty for an HTML-only message empties the inbox preview
        // for most marketing mail there is.
        let parsed = parse("""
        From: a@b.com
        Content-Type: text/html

        <p>Only markup here</p>
        """)
        XCTAssertEqual(parsed.text?.contains("Only markup here"), true)
        XCTAssertEqual(parsed.text?.contains("<p>"), false)
    }

    func testNestedMultipartIsWalked() {
        let parsed = parse("""
        From: a@b.com
        Content-Type: multipart/mixed; boundary="OUT"

        --OUT
        Content-Type: multipart/alternative; boundary="IN"

        --IN
        Content-Type: text/plain

        the words
        --IN--
        --OUT
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Disposition: attachment; filename="invoice.pdf"

        JVBERi0=
        --OUT--
        """)

        XCTAssertEqual(parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), "the words")
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments.first?.filename, "invoice.pdf")
    }

    func testAttachmentsCarryTheirIMAPSection() {
        // The section is how the bytes are fetched later without pulling the
        // whole message again. Getting it wrong downloads the wrong part.
        let parsed = parse("""
        From: a@b.com
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        hi
        --B
        Content-Type: image/png; name="one.png"
        Content-Disposition: attachment; filename="one.png"

        x
        --B
        Content-Type: image/png; name="two.png"
        Content-Disposition: attachment; filename="two.png"

        y
        --B--
        """)

        XCTAssertEqual(parsed.attachments.map(\.section), ["2", "3"])
    }

    func testAnEncodedAttachmentNameIsDecoded() {
        let parsed = parse("""
        From: a@b.com
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="=?UTF-8?B?cmVjaG51bmcucGRm?="

        x
        --B--
        """)
        XCTAssertEqual(parsed.attachments.first?.filename, "rechnung.pdf")
    }

    func testTheClosingBoundaryEndsIt() {
        // Servers append trailing noise after the closing boundary. Reading it
        // as another part invents an empty attachment on a lot of mail.
        let parsed = parse("""
        From: a@b.com
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        real
        --B--

        this trailing text is not a part
        """)
        XCTAssertEqual(parsed.attachments.count, 0)
        XCTAssertEqual(parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), "real")
    }

    // MARK: - Addresses

    func testItSplitsSeveralRecipients() {
        let parsed = parse("""
        From: a@b.com
        To: One <one@x.com>, two@y.com

        body
        """)
        XCTAssertEqual(parsed.to.map(\.address), ["one@x.com", "two@y.com"])
    }

    func testACommaInsideAQuotedNameIsNotASeparator() {
        // "Lovelace, Ada" is one person. Splitting on every comma makes two,
        // one of which has no address at all.
        let parsed = parse("""
        From: a@b.com
        To: "Lovelace, Ada" <ada@x.com>, bob@y.com

        body
        """)
        XCTAssertEqual(parsed.to.count, 2)
        XCTAssertEqual(parsed.to.first?.name, "Lovelace, Ada")
        XCTAssertEqual(parsed.to.first?.address, "ada@x.com")
    }

    func testABareAddressGetsAName() {
        let parsed = parse("""
        From: solo@example.com

        body
        """)
        XCTAssertEqual(parsed.from?.address, "solo@example.com")
    }

    func testAnEncodedDisplayNameIsDecoded() {
        let parsed = parse("""
        From: =?UTF-8?B?w4VzYSBOw7hyZ2FyZA==?= <asa@x.com>

        body
        """)
        XCTAssertEqual(parsed.from?.name, "Åsa Nørgard")
    }

    // MARK: - Dates

    func testItReadsAnRFC5322Date() throws {
        let date = try XCTUnwrap(MIMEParser.parseDate("Tue, 15 Nov 1994 12:45:26 +0100"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3600))
        XCTAssertEqual(calendar.component(.year, from: date), 1994)
        XCTAssertEqual(calendar.component(.hour, from: date), 12)
    }

    func testItReadsADateWithATrailingComment() {
        // "(GMT)" after the offset is legal and common from older servers.
        XCTAssertNotNil(MIMEParser.parseDate("Tue, 15 Nov 1994 12:45:26 +0000 (GMT)"))
    }

    func testItReadsADateWithNoWeekday() {
        XCTAssertNotNil(MIMEParser.parseDate("15 Nov 1994 12:45:26 +0100"))
    }

    func testAnUnreadableDateIsNilRatherThanWrong() {
        XCTAssertNil(MIMEParser.parseDate("sometime last week"))
    }
}
