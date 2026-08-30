import XCTest
@testable import EmailApp

final class GmailParsingTests: XCTestCase {

    // MARK: - From header

    func testParsesDisplayNameAndAddress() {
        let contact = GmailService.contact(from: "Abel Amare <abel@example.com>")
        XCTAssertEqual(contact.name, "Abel Amare")
        XCTAssertEqual(contact.address, "abel@example.com")
    }

    func testStripsQuotesAroundDisplayName() {
        let contact = GmailService.contact(from: "\"Amare, Abel\" <abel@example.com>")
        XCTAssertEqual(contact.name, "Amare, Abel")
        XCTAssertEqual(contact.address, "abel@example.com")
    }

    func testBareAddressBecomesItsOwnName() {
        let contact = GmailService.contact(from: "abel@example.com")
        XCTAssertEqual(contact.address, "abel@example.com")
        XCTAssertEqual(contact.name, "abel@example.com")
    }

    func testAngleBracketsInsideTheDisplayNameDoNotBreakParsing() {
        // The LAST pair of brackets is the address, not the first.
        let contact = GmailService.contact(from: "<weird> name <real@example.com>")
        XCTAssertEqual(contact.address, "real@example.com")
    }

    func testEmptyHeaderDoesNotCrash() {
        XCTAssertEqual(GmailService.contact(from: "").name, "Unknown")
    }

    // MARK: - Body

    func testDecodesBase64URLWithoutPadding() {
        // "Hello, Maily!" base64url encoded, padding stripped as Gmail does.
        XCTAssertEqual(GmailService.decode("SGVsbG8sIE1haWx5IQ"), "Hello, Maily!")
    }

    func testDecodesBase64URLSubstitutedCharacters() {
        // base64url swaps + and / for - and _
        let standard = Data("a?b>c".utf8).base64EncodedString()
        let urlSafe = standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(GmailService.decode(urlSafe), "a?b>c")
    }

    func testFindsPlainTextInsideAMultipartTree() {
        let payload: [String: Any] = [
            "mimeType": "multipart/alternative",
            "parts": [
                ["mimeType": "text/html", "body": ["data": encode("<p>html</p>")]],
                ["mimeType": "text/plain", "body": ["data": encode("the plain one")]],
            ],
        ]
        XCTAssertEqual(GmailService.plainText(from: payload), "the plain one")
    }

    func testFallsBackToStrippedHTMLWhenThereIsNoPlainPart() {
        let payload: [String: Any] = [
            "mimeType": "text/html",
            "body": ["data": encode("<p>Hello&nbsp;<b>there</b></p>")],
        ]
        XCTAssertEqual(GmailService.plainText(from: payload), "Hello there")
    }

    func testStripsTagsAndEntities() {
        let html = "<div>Tom &amp; Jerry &lt;3</div>"
        XCTAssertEqual(GmailService.strippingHTML(html), "Tom & Jerry <3")
    }

    // MARK: - Whole message

    func testParsesAFullMessage() {
        let json: [String: Any] = [
            "id": "abc",
            "labelIds": ["INBOX", "UNREAD", "STARRED"],
            "snippet": "a snippet",
            "internalDate": "1700000000000",
            "payload": [
                "mimeType": "text/plain",
                "headers": [
                    ["name": "From", "value": "Sara Bekele <sara@example.com>"],
                    ["name": "To", "value": "me@example.com"],
                    ["name": "Subject", "value": "Design review"],
                ],
                "body": ["data": encode("Thursday at 2 works.")],
            ],
        ]

        let message = GmailService.parse(json)
        XCTAssertEqual(message?.sender.name, "Sara Bekele")
        XCTAssertEqual(message?.subject, "Design review")
        XCTAssertEqual(message?.body, "Thursday at 2 works.")
        XCTAssertEqual(message?.isRead, false, "UNREAD label means not read")
        XCTAssertEqual(message?.isFlagged, true, "STARRED maps to flagged")
        XCTAssertEqual(message?.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testHeaderLookupIsCaseInsensitive() {
        let json: [String: Any] = [
            "labelIds": ["INBOX"],
            "internalDate": "1700000000000",
            "payload": [
                "headers": [["name": "SUBJECT", "value": "Shouty header"]],
                "body": ["data": encode("body")],
                "mimeType": "text/plain",
            ],
        ]
        XCTAssertEqual(GmailService.parse(json)?.subject, "Shouty header")
    }

    func testMissingSubjectGetsAPlaceholder() {
        let json: [String: Any] = [
            "labelIds": [],
            "internalDate": "1700000000000",
            "payload": ["headers": [], "mimeType": "text/plain", "body": ["data": encode("x")]],
        ]
        XCTAssertEqual(GmailService.parse(json)?.subject, "(No Subject)")
    }

    func testMessageWithoutPayloadIsRejectedRatherThanCrashing() {
        XCTAssertNil(GmailService.parse(["id": "abc"]))
    }

    private func encode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class MessageClassifierTests: XCTestCase {

    private func message(subject: String = "Hello", body: String = "Hi there", sender: String = "Sara Bekele", read: Bool = true) -> Message {
        Message(
            sender: Contact(name: sender, address: "sara@example.com"),
            recipients: [],
            subject: subject,
            body: body,
            date: .now,
            isRead: read
        )
    }

    // MARK: - Bulk short-circuit

    func testListUnsubscribeMeansBulk() {
        XCTAssertTrue(MessageClassifier.isBulk(
            headers: ["list-unsubscribe": "<https://x.com/u>"], labels: [], sender: "news@x.com"))
    }

    func testPromotionsCategoryMeansBulk() {
        XCTAssertTrue(MessageClassifier.isBulk(
            headers: [:], labels: ["CATEGORY_PROMOTIONS"], sender: "shop@x.com"))
    }

    func testNoReplyAddressMeansBulk() {
        XCTAssertTrue(MessageClassifier.isBulk(headers: [:], labels: [], sender: "no-reply@x.com"))
    }

    func testAnOrdinaryPersonIsNotBulk() {
        XCTAssertFalse(MessageClassifier.isBulk(headers: [:], labels: ["INBOX"], sender: "sara@example.com"))
    }

    func testBulkMailIsTaggedNoReplyNeededAndNothingElse() {
        // Even with urgent-sounding words, a newsletter is still a newsletter.
        let tags = MessageClassifier.tags(
            for: message(subject: "URGENT: final notice, act today!"),
            headers: ["list-unsubscribe": "<https://x.com/u>"],
            labels: []
        )
        XCTAssertEqual(tags, [.noReplyNeeded])
    }

    // MARK: - Reply detection

    func testQuestionInSubjectWantsAReply() {
        XCTAssertTrue(MessageClassifier.wantsReply(subject: "Are you free?", body: "", haystack: "are you free?"))
    }

    func testAskPhraseInBodyWantsAReply() {
        XCTAssertTrue(MessageClassifier.wantsReply(
            subject: "Proposal", body: "Could you confirm the numbers", haystack: "proposal could you confirm the numbers"))
    }

    func testAStatementDoesNotWantAReply() {
        XCTAssertFalse(MessageClassifier.wantsReply(
            subject: "Notes attached", body: "Sending these over for your records.",
            haystack: "notes attached sending these over for your records."))
    }

    // MARK: - Scoring

    func testUrgentLanguageEarnsTheUrgentTag() {
        let tags = MessageClassifier.tags(
            for: message(subject: "URGENT: sign-off needed by 5pm", body: "Deadline today.", read: false),
            headers: [:],
            labels: ["INBOX", "IMPORTANT"]
        )
        XCTAssertTrue(tags.contains(.urgent))
    }

    func testStarredMailRanksAbovePlainMail() {
        let plain = MessageClassifier.score(
            message: message(), labels: ["INBOX"], haystack: "hello hi there")
        let starred = MessageClassifier.score(
            message: message(), labels: ["INBOX", "STARRED"], haystack: "hello hi there")
        XCTAssertGreaterThan(starred, plain)
    }

    func testAClockTimeIsTreatedAsADeadlineHint() {
        XCTAssertTrue(MessageClassifier.containsClockTime("can you send it by 5pm"))
        XCTAssertTrue(MessageClassifier.containsClockTime("the call is at 14:30"))
        XCTAssertFalse(MessageClassifier.containsClockTime("no times mentioned here"))
    }

    func testOrdinaryMailIsStillTaggedRatherThanLeftBlank() {
        // A fully untagged message would show up in no filter at all.
        let tags = MessageClassifier.tags(
            for: message(subject: "FYI", body: "Just so you know."), headers: [:], labels: ["INBOX"])
        XCTAssertFalse(tags.isEmpty)
    }
}
