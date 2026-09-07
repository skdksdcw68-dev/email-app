import XCTest
@testable import EmailApp

/// The reader is the security boundary of a mail app: everything in it was
/// written by a stranger. These pin the two promises made on the Privacy
/// screen -- pictures are not fetched, and a link says where it goes.
@MainActor
final class ReaderPrivacyTests: XCTestCase {

    // MARK: - What a message would fetch

    func testAMessageWithARemoteImageIsNoticed() {
        let html = #"<p>Hi</p><img src="https://track.example.com/open.gif?id=42" width="1">"#
        XCTAssertTrue(HTMLMessageView.wantsRemoteContent(html))
    }

    func testABackgroundImageCountsToo() {
        // The tracking pixel that hides from anybody looking for <img>.
        let html = #"<div style="background-image:url('https://t.example.com/p.png')">x</div>"#
        XCTAssertTrue(HTMLMessageView.wantsRemoteContent(html))
    }

    func testAStylesheetCountsToo() {
        let html = #"<link rel="stylesheet" href="https://cdn.example.com/mail.css">"#
        XCTAssertTrue(HTMLMessageView.wantsRemoteContent(html))
    }

    func testAPlainMessageCarriesNoNotice() {
        // 🔴 A banner on a message that was never going to fetch anything
        // teaches people to tap Show without reading it.
        XCTAssertFalse(HTMLMessageView.wantsRemoteContent("<p>Hello, are we still on for 3?</p>"))
    }

    func testAnInlinedPictureIsNotRemote() {
        // It arrived with the message. Nobody learns anything from it.
        let html = #"<img src="data:image/png;base64,iVBORw0KGgo=">"#
        XCTAssertFalse(HTMLMessageView.wantsRemoteContent(html))
    }

    func testACarriedPictureIsNotRemote() {
        let html = #"<img src="cid:logo@example.com">"#
        XCTAssertFalse(HTMLMessageView.wantsRemoteContent(html))
    }

    // MARK: - The fallback, when WebKit will not compile a rule list

    func testStrippingLeavesNoRemoteReference() {
        let html = """
        <img src="https://track.example.com/open.gif">
        <div style="background-image:url(http://t.example.com/p.png)"></div>
        <link rel="stylesheet" href="https://cdn.example.com/m.css">
        <table background="https://bg.example.com/tile.png"><tr><td>hi</td></tr></table>
        """
        let stripped = HTMLMessageView.strippingRemoteContent(html)

        XCTAssertFalse(stripped.contains("track.example.com"), stripped)
        XCTAssertFalse(stripped.contains("t.example.com"), stripped)
        XCTAssertFalse(stripped.contains("cdn.example.com"), stripped)
        XCTAssertFalse(stripped.contains("bg.example.com"), stripped)
        XCTAssertTrue(stripped.contains("hi"), "the message itself survives")
    }

    func testStrippingKeepsWhatCameWithTheMessage() {
        let html = #"<img src="cid:logo@x"><img src="data:image/png;base64,AA">"#
        XCTAssertEqual(HTMLMessageView.strippingRemoteContent(html), html)
    }

    func testStrippingIsSafeToRunTwice() {
        let html = #"<img src="https://track.example.com/open.gif">"#
        let once = HTMLMessageView.strippingRemoteContent(html)
        XCTAssertEqual(HTMLMessageView.strippingRemoteContent(once), once)
    }

    // MARK: - Who sent it

    func testANameCarryingADifferentAddressIsFlagged() {
        let contact = Contact(name: "billing@paypal.com", address: "noreply@invoice-2847.top")
        let warning = SenderScrutiny.check(contact)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.detail.contains("invoice-2847.top") == true)
    }

    func testABrandNameFromTheWrongDomainIsFlagged() {
        let contact = Contact(name: "PayPal Support", address: "security@paypa1-verify.com")
        XCTAssertEqual(SenderScrutiny.check(contact)?.headline, "This may not be PayPal")
    }

    func testTheRealBrandFromItsOwnDomainIsNotFlagged() {
        XCTAssertNil(SenderScrutiny.check(Contact(name: "PayPal", address: "service@paypal.com")))
    }

    func testASubdomainOfTheRealBrandIsNotFlagged() {
        // Real senders use them constantly: email.apple.com, mail.google.com.
        XCTAssertNil(SenderScrutiny.check(Contact(name: "Apple", address: "no_reply@email.apple.com")))
        XCTAssertNil(SenderScrutiny.check(Contact(name: "Google", address: "no-reply@accounts.google.com")))
    }

    func testALookAlikeDomainIsFlagged() {
        let contact = Contact(name: "Support", address: "help@xn--pple-43d.com")
        XCTAssertTrue(SenderScrutiny.check(contact)?.headline.contains("look-alike") == true)
    }

    func testAnOrdinaryPersonIsNeverFlagged() {
        // 🔴 The failure mode that matters. A warning people see on normal
        // mail is a warning they stop reading.
        let ordinary = [
            Contact(name: "Abel Amare", address: "abelamare1633@gmail.com"),
            Contact(name: "Sarah", address: "sarah@acme.co"),
            Contact(name: "Netro Billing", address: "billing@netro.dev"),
            Contact(name: "", address: "noreply@example.com"),
        ]
        for contact in ordinary {
            XCTAssertNil(SenderScrutiny.check(contact), "flagged \(contact.address)")
        }
    }

    func testTheSameAddressInTheNameIsNotAWarning() {
        let contact = Contact(name: "support@acme.co", address: "support@acme.co")
        XCTAssertNil(SenderScrutiny.check(contact))
    }
}
