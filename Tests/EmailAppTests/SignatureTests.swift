import XCTest
@testable import EmailApp

/// The sign-off, and when it is used.
@MainActor
final class SignatureTests: XCTestCase {

    private var savedSignature = ""
    private var savedSignsReplies = false

    override func setUp() {
        super.setUp()
        savedSignature = AppSettings.signature
        savedSignsReplies = AppSettings.signsReplies
    }

    override func tearDown() {
        AppSettings.signature = savedSignature
        AppSettings.signsReplies = savedSignsReplies
        super.tearDown()
    }

    func testNoSignatureChangesNothing() {
        // The default. Nobody's mail gets an advertisement they did not write.
        AppSettings.signature = ""
        XCTAssertEqual(ComposeView.signed("Hello", replying: false), "Hello")
    }

    func testWhitespaceOnlyIsNoSignature() {
        AppSettings.signature = "   \n  "
        XCTAssertEqual(ComposeView.signed("Hello", replying: false), "Hello")
    }

    func testANewMessageIsSigned() {
        AppSettings.signature = "Abel"
        XCTAssertEqual(ComposeView.signed("", replying: false), "\n\n-- \nAbel")
    }

    func testTheDelimiterIsDashDashSpace() {
        // The convention other mail apps read to tell a signature from the
        // message. Losing the trailing space breaks it.
        AppSettings.signature = "Abel"
        XCTAssertTrue(ComposeView.signed("Hi", replying: false).contains("\n-- \n"))
    }

    func testRepliesAreLeftAloneByDefault() {
        // A signature under every line of a fast back-and-forth turns a
        // thread into a wall of contact details.
        AppSettings.signature = "Abel"
        AppSettings.signsReplies = false
        XCTAssertEqual(ComposeView.signed("Sure", replying: true), "Sure")
    }

    func testRepliesAreSignedWhenAsked() {
        AppSettings.signature = "Abel"
        AppSettings.signsReplies = true
        XCTAssertEqual(ComposeView.signed("Sure", replying: true), "Sure\n\n-- \nAbel")
    }

    func testTheDraftedTextComesFirst() {
        AppSettings.signature = "Abel"
        let signed = ComposeView.signed("The answer is yes.", replying: false)
        XCTAssertTrue(signed.hasPrefix("The answer is yes."))
        XCTAssertTrue(signed.hasSuffix("Abel"))
    }

    func testAMultiLineSignatureIsKeptWhole() {
        AppSettings.signature = "Abel Amare\nMaily\nabel@maily.app"
        XCTAssertEqual(
            ComposeView.signed("", replying: false),
            "\n\n-- \nAbel Amare\nMaily\nabel@maily.app"
        )
    }
}
