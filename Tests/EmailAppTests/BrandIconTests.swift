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

    func testSubdomainIsKept() {
        XCTAssertEqual(BrandIcon.domain(for: "no-reply@mail.notion.so"), "mail.notion.so")
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
