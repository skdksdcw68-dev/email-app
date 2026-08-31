import XCTest
@testable import EmailApp

/// The kind tags -- what a message *is*, as opposed to how much it matters.
final class TagKindTests: XCTestCase {

    private func message(subject: String, body: String = "", from: String = "sara@example.com") -> Message {
        Message(
            sender: Contact(name: "Sara", address: from),
            recipients: [],
            subject: subject,
            body: body,
            date: .now
        )
    }

    private func kind(_ subject: String, body: String = "", from: String = "sara@example.com",
                      headers: [String: String] = [:], labels: Set<String> = []) -> AITag? {
        MessageClassifier.kind(
            for: message(subject: subject, body: body, from: from),
            headers: headers,
            labels: labels
        )
    }

    // MARK: - Each kind

    func testSignInAlertIsSecurity() {
        XCTAssertEqual(kind("Security alert", body: "You allowed Maily access"), .security)
    }

    func testVerificationCodeIsSecurity() {
        XCTAssertEqual(kind("Your verification code"), .security)
    }

    func testInvoiceIsFinance() {
        XCTAssertEqual(kind("Invoice 4471 is ready"), .finance)
    }

    func testCalendarInviteIsMeeting() {
        XCTAssertEqual(kind("Invitation: design review"), .meeting)
    }

    func testDiscountIsPromotion() {
        XCTAssertEqual(kind("30% off everything this weekend"), .promotion)
    }

    func testPromotionsLabelIsPromotion() {
        XCTAssertEqual(kind("Anything at all", labels: ["CATEGORY_PROMOTIONS"]), .promotion)
    }

    func testListUnsubscribeIsNewsletter() {
        XCTAssertEqual(kind("Weekly roundup", headers: ["list-unsubscribe": "<https://x.com/u>"]), .newsletter)
    }

    func testOrdinaryMailHasNoKind() {
        XCTAssertNil(kind("Lunch tomorrow?", body: "Peak bro"))
    }

    // MARK: - Precedence

    func testSecurityBeatsNewsletterFooter() {
        // A sign-in alert that happens to carry an unsubscribe footer is a
        // security mail, not a newsletter.
        XCTAssertEqual(
            kind("Security alert", headers: ["list-unsubscribe": "<https://x.com/u>"]),
            .security
        )
    }

    func testPromotionBeatsNewsletter() {
        // Almost every promotion is technically also a bulk send, so the more
        // specific one has to win or nothing would ever be tagged Promotion.
        XCTAssertEqual(
            kind("Limited time: 50% off", headers: ["list-unsubscribe": "<https://x.com/u>"]),
            .promotion
        )
    }

    // MARK: - Interaction with priority

    func testAKindDoesNotSatisfyTheStatusFallback() {
        // A message showing only "Newsletter" would sit in no status filter.
        // The fallback has to still fire.
        let tags = MessageClassifier.tags(
            for: message(subject: "Invoice 4471 is ready"),
            headers: [:],
            labels: ["INBOX"]
        )
        XCTAssertTrue(tags.contains(.finance))
        XCTAssertFalse(tags.intersection([.needsReply, .noReplyNeeded]).isEmpty)
    }

    func testUrgentFinanceCarriesBoth() {
        let tags = MessageClassifier.tags(
            for: message(subject: "URGENT: payment due today", body: "Deadline today by 5pm.", from: "billing@acme.com"),
            headers: [:],
            labels: ["INBOX", "IMPORTANT", "STARRED"]
        )
        XCTAssertTrue(tags.contains(.finance))
        XCTAssertTrue(tags.contains(.urgent))
    }

    // MARK: - Model vocabulary

    func testModelCategoriesMapOntoTags() {
        XCTAssertEqual(AITag.kind(named: "meeting"), .meeting)
        XCTAssertEqual(AITag.kind(named: "finance"), .finance)
        XCTAssertEqual(AITag.kind(named: "security"), .security)
        XCTAssertEqual(AITag.kind(named: "newsletter"), .newsletter)
        XCTAssertEqual(AITag.kind(named: "promotion"), .promotion)
    }

    func testOtherAndNonsenseMapToNoKind() {
        XCTAssertNil(AITag.kind(named: "other"))
        XCTAssertNil(AITag.kind(named: ""))
        XCTAssertNil(AITag.kind(named: "URGENT"))
    }

    func testEveryKindIsListedInKinds() {
        // Guards the subtract() in MailStore.apply: a kind missing from this
        // list would never be cleared when a message is reclassified.
        for tag in AITag.allCases where tag.priorityRank == nil {
            let isStatus = tag == .needsReply || tag == .noReplyNeeded
            if !isStatus {
                XCTAssertTrue(AITag.kinds.contains(tag), "\(tag) is missing from AITag.kinds")
            }
        }
    }
}
