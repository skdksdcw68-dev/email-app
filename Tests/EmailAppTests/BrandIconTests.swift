import XCTest
@testable import EmailApp

final class BrandIconTests: XCTestCase {

    // MARK: - Which senders get a logo looked up

    func testCompanyDomainIsLookedUp() {
        XCTAssertEqual(BrandIcon.domain(for: "billing@stripe.com"), "stripe.com")
    }

    func testConsumerDomainIsSkipped() {
        // Mail from a gmail.com address is from a person. Showing Gmail's logo
        // for every one of them tells the reader nothing.
        XCTAssertNil(BrandIcon.domain(for: "abel@gmail.com"))
        XCTAssertNil(BrandIcon.domain(for: "someone@icloud.com"))
        XCTAssertNil(BrandIcon.domain(for: "someone@proton.me"))
    }

    func testDomainIsLowercased() {
        XCTAssertEqual(BrandIcon.domain(for: "Noreply@GitHub.COM"), "github.com")
    }

    func testConsumerCheckIsCaseInsensitive() {
        XCTAssertNil(BrandIcon.domain(for: "Abel@Gmail.Com"))
    }

    // MARK: - Stripping to the organisation

    /// 🔴 This test asserted the opposite, and the old assertion was the bug.
    ///
    /// Keeping the subdomain is why most of an inbox had no logo. Companies do
    /// not send from their homepage domain -- it is `mail.notion.so`,
    /// `e.tiktok.com`, `notifications.github.com` -- and every icon service
    /// there is answers 404 for those. Checked against the live services: both
    /// Google's and DuckDuckGo's return a 404 for `e.tiktok.com` and a real
    /// logo for `tiktok.com`.
    func testSubdomainIsStrippedToTheOrganisation() {
        XCTAssertEqual(BrandIcon.domain(for: "no-reply@mail.notion.so"), "notion.so")
        XCTAssertEqual(BrandIcon.domain(for: "hello@e.tiktok.com"), "tiktok.com")
        XCTAssertEqual(
            BrandIcon.domain(for: "noreply@notifications.github.com"), "github.com"
        )
    }

    /// A two-label public suffix has to keep three labels, or the "company"
    /// becomes `co.uk` and every British sender shares one logo.
    func testTwoLabelSuffixKeepsTheOrganisation() {
        XCTAssertEqual(BrandIcon.domain(for: "news@mail.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(BrandIcon.domain(for: "info@cbe.com.et"), "cbe.com.et")
        XCTAssertEqual(BrandIcon.domain(for: "x@a.b.telstra.com.au"), "telstra.com.au")
    }

    /// The organisation of a bare domain is itself -- nothing to strip.
    func testPlainDomainIsUnchanged() {
        XCTAssertEqual(BrandIcon.domain(for: "billing@stripe.com"), "stripe.com")
        XCTAssertEqual(BrandIcon.domain(for: "a@notion.so"), "notion.so")
    }

    /// Stripping happens before the consumer check, or mail from
    /// `googlemail.com`'s own sending hosts would be given Google's logo.
    func testConsumerCheckAppliesAfterStripping() {
        XCTAssertNil(BrandIcon.domain(for: "someone@mail.gmail.com"))
    }

    // MARK: - Reading a BIMI record

    /// The two spacings both occur in the wild. Checked against the live
    /// records: eBay publishes `v=BIMI1;l=...` with no spaces, Bank of America
    /// publishes `v=BIMI1; l=...` with them.
    func testLogoIsReadWithAndWithoutSpaces() {
        XCTAssertEqual(
            BrandIcon.logoURL(in: "v=BIMI1;l=https://bimi.entrust.net/tiktok.com/logo.svg;a=https://x/c.pem"),
            URL(string: "https://bimi.entrust.net/tiktok.com/logo.svg")
        )
        XCTAssertEqual(
            BrandIcon.logoURL(in: "v=BIMI1; l=https://vmc.digicert.com/a.svg; a=https://vmc.digicert.com/a.pem"),
            URL(string: "https://vmc.digicert.com/a.svg")
        )
    }

    /// A TXT record over 255 bytes arrives as several quoted strings. Joining
    /// them before unquoting is the difference between a URL and a URL with a
    /// space in the middle of it.
    func testSplitRecordIsJoinedBeforeUnquoting() {
        let split = "\"v=BIMI1; l=https://vmc.digicert.com/very-long-\" \"identifier.svg; a=https://x/c.pem\""
        XCTAssertEqual(
            BrandIcon.logoURL(in: split),
            URL(string: "https://vmc.digicert.com/very-long-identifier.svg")
        )
    }

    /// An empty `l=` is legal and means "we deliberately have no logo".
    func testEmptyLogoIsNotAURL() {
        XCTAssertNil(BrandIcon.logoURL(in: "v=BIMI1; l=; a=https://x/c.pem"))
    }

    func testRecordWithoutALogoIsNil() {
        XCTAssertNil(BrandIcon.logoURL(in: "v=BIMI1; a=https://x/c.pem"))
    }

    /// ⚠️ A logo has to come over TLS. Anything else is a picture an attacker
    /// on the network chooses, drawn next to a sender's name.
    func testInsecureLogoIsRefused() {
        XCTAssertNil(BrandIcon.logoURL(in: "v=BIMI1; l=http://example.com/logo.svg"))
    }

    // MARK: - Malformed addresses

    func testAddressWithoutAtSignIsSkipped() {
        XCTAssertNil(BrandIcon.domain(for: "not-an-address"))
    }

    func testHostWithoutDotIsSkipped() {
        XCTAssertNil(BrandIcon.domain(for: "root@localhost"))
    }

    func testEmptyAddressIsSkipped() {
        XCTAssertNil(BrandIcon.domain(for: ""))
    }

    func testTrailingAtSignIsSkipped() {
        XCTAssertNil(BrandIcon.domain(for: "abel@"))
    }
}
