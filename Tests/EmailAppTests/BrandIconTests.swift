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

/// Gravatar is the one picture still fetched from the phone, and the reason is
/// privacy rather than convenience: it is keyed on the *address*, and routing
/// it through Maily's own server would put a list of who writes to somebody on
/// a server with no other reason to know.
final class GravatarTests: XCTestCase {

    /// 🔴 `d=404` is load-bearing. Without it Gravatar answers every miss with
    /// a generated pattern, so every person in the inbox gets a procedural
    /// blob instead of their own initial.
    func testMissesAreRefusedRatherThanInvented() {
        let url = BrandIcon.gravatarURL(for: "abel@gmail.com")
        XCTAssertEqual(url?.query?.contains("d=404"), true)
    }

    /// The hash is of the trimmed, lowercased address -- Gravatar's own rule.
    /// Getting it wrong means every lookup misses and nobody ever notices,
    /// because a miss looks exactly like "they have no Gravatar".
    func testAddressIsNormalisedBeforeHashing() {
        XCTAssertEqual(
            BrandIcon.gravatarURL(for: "  Abel@Gmail.COM "),
            BrandIcon.gravatarURL(for: "abel@gmail.com")
        )
    }

    func testSomethingThatIsNotAnAddressIsRefused() {
        XCTAssertNil(BrandIcon.gravatarURL(for: "not-an-address"))
    }

    /// Namespaced, or a person's Gravatar and their company's logo would
    /// overwrite each other in the image cache.
    func testKeyIsNamespaced() throws {
        let logo = try XCTUnwrap(URL(string: "https://b.com/apple-touch-icon.png"))
        XCTAssertNotEqual(
            BrandIcon.gravatarKey(for: "a@b.com"),
            LogoDirectory.key(for: "b.com", url: logo)
        )
    }
}
