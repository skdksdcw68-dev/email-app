import XCTest
@testable import EmailApp

/// The email the model writes must come out of the prose whole, with the
/// envelope parsed, so it can become a card with a Send button.
final class EmailBlockTests: XCTestCase {

    func testABlockIsLiftedOutOfTheProse() {
        let text = """
        Here is a draft you can send.

        ```email
        To: App Store Connect <no_reply@email.apple.com>
        Subject: Question about my submission

        Hello,

        Could you share the specific reason for the issue?

        Thank you
        ```

        Tell me if you want it firmer.
        """

        let result = EmailBlock.extract(from: text)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.prose, "Here is a draft you can send.\n\nTell me if you want it firmer.")
        XCTAssertEqual(result?.email.toName, "App Store Connect")
        XCTAssertEqual(result?.email.toAddress, "no_reply@email.apple.com")
        XCTAssertEqual(result?.email.subject, "Question about my submission")
        XCTAssertEqual(result?.email.body, "Hello,\n\nCould you share the specific reason for the issue?\n\nThank you")
    }

    func testAnUnfinishedBlockIsNotExtracted() {
        // Mid-stream: the fence has opened but not closed. Nothing to lift
        // yet, and the prose view shows "Writing the email" instead.
        XCTAssertNil(EmailBlock.extract(from: "Sure.\n\n```email\nTo: sara@x.com\nSubject: Hi\n\nHello"))
    }

    func testBoldedLabelsAndABareAddressStillParse() {
        let block = EmailBlock.parse("**To:** sara@x.com\n**Subject:** Thursday\n\nWorks for me.")
        XCTAssertEqual(block.toName, "")
        XCTAssertEqual(block.toAddress, "sara@x.com")
        XCTAssertEqual(block.subject, "Thursday")
        XCTAssertEqual(block.body, "Works for me.")
    }

    func testANameWithoutAnAddressLeavesTheAddressEmpty() {
        let block = EmailBlock.parse("To: Sara\nSubject: Hi\n\nHello")
        XCTAssertEqual(block.toName, "Sara")
        XCTAssertEqual(block.toAddress, "")
    }

    func testTextWithoutABlockIsLeftAlone() {
        XCTAssertNil(EmailBlock.extract(from: "Nothing in your recent mail covers that."))
    }
}
