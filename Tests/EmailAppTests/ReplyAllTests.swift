import XCTest
@testable import EmailApp

/// Who a reply-all actually goes to.
///
/// The list is the whole feature, and getting it wrong is not a cosmetic
/// bug: an address too many is a private answer sent to a room, and an
/// address too few is an answer somebody never sees.
@MainActor
final class ReplyAllTests: XCTestCase {

    private func message(
        from sender: String,
        to recipients: [String]
    ) -> Message {
        Message(
            sender: Contact(name: "", address: sender),
            recipients: recipients.map { Contact(name: "", address: $0) },
            subject: "Plans",
            body: "",
            date: .now
        )
    }

    func testEverybodyOnTheMessageIsIncluded() {
        let original = message(from: "sarah@acme.co", to: ["me@maily.app", "john@acme.co", "kim@acme.co"])

        let others = ComposeView.everyoneElse(on: original, mine: "me@maily.app")

        XCTAssertEqual(others, ["john@acme.co", "kim@acme.co"])
    }

    func testTheSenderIsNotAddedTwice() {
        // They are already in To. A reply-all that Ccs the sender puts two
        // copies of the answer in their inbox.
        let original = message(from: "sarah@acme.co", to: ["me@maily.app", "sarah@acme.co"])

        XCTAssertEqual(ComposeView.everyoneElse(on: original, mine: "me@maily.app"), [])
    }

    func testYouAreLeftOut() {
        let original = message(from: "sarah@acme.co", to: ["me@maily.app"])

        XCTAssertEqual(ComposeView.everyoneElse(on: original, mine: "me@maily.app"), [])
    }

    func testYouAreLeftOutWhateverTheCase() {
        // Addresses arrive from a dozen servers with a dozen ideas about
        // capitals. Matching on the raw string would put somebody on their
        // own reply.
        let original = message(from: "Sarah@Acme.co", to: ["Me@Maily.app", "john@acme.co"])

        XCTAssertEqual(ComposeView.everyoneElse(on: original, mine: "me@maily.app"), ["john@acme.co"])
    }

    func testTheSameAddressTwiceAppearsOnce() {
        let original = message(
            from: "sarah@acme.co",
            to: ["john@acme.co", "JOHN@acme.co", "kim@acme.co"]
        )

        XCTAssertEqual(ComposeView.everyoneElse(on: original, mine: "me@maily.app"),
                       ["john@acme.co", "kim@acme.co"])
    }

    func testTheOriginalCasingIsKept() {
        // Lowercased for comparison, sent as written: some servers still
        // treat the local part as case-sensitive, and it is not this app's
        // place to rewrite somebody's address.
        let original = message(from: "sarah@acme.co", to: ["John.Smith@Acme.co"])

        XCTAssertEqual(ComposeView.everyoneElse(on: original, mine: "me@maily.app"),
                       ["John.Smith@Acme.co"])
    }

    func testNoMailboxConnectedStillProducesTheOthers() {
        let original = message(from: "sarah@acme.co", to: ["john@acme.co"])

        XCTAssertEqual(ComposeView.everyoneElse(on: original, mine: nil), ["john@acme.co"])
    }

    func testAMessageToOneNeedsNoReplyAll() {
        // What the button hides on.
        let original = message(from: "sarah@acme.co", to: ["me@maily.app"])

        XCTAssertTrue(ComposeView.everyoneElse(on: original, mine: "me@maily.app").isEmpty)
    }
}
