import XCTest
@testable import EmailApp

/// What the free allowance is spent on: the newest mail, not the oldest.
final class FreeTierSortingTests: XCTestCase {

    private func mailbox(count: Int) -> [Message] {
        // Oldest first in the array, so "newest" has to come from the dates
        // and not from the order the messages happen to arrive in.
        (0..<count).map { index in
            Message(
                sender: Contact(name: "Someone", address: "someone@example.com"),
                recipients: [],
                subject: "Message \(index)",
                body: "",
                date: Date(timeIntervalSince1970: TimeInterval(index) * 60)
            )
        }
    }

    func testFreeSortsTheNewestThousand() throws {
        let messages = mailbox(count: 1_200)
        let eligible = try XCTUnwrap(MailStore.eligibleForAI(messages, tier: .free))

        XCTAssertEqual(eligible.count, MailStore.freeSortingDepth)
        // The newest is in, the oldest is out.
        XCTAssertTrue(eligible.contains(messages[1_199].id))
        XCTAssertFalse(eligible.contains(messages[0].id))
        XCTAssertFalse(eligible.contains(messages[199].id))
        XCTAssertTrue(eligible.contains(messages[200].id))
    }

    func testASmallMailboxIsSortedWhole() throws {
        let messages = mailbox(count: 40)
        let eligible = try XCTUnwrap(MailStore.eligibleForAI(messages, tier: .free))
        XCTAssertEqual(eligible.count, 40)
    }

    func testPaidPlansSortEverything() {
        let messages = mailbox(count: 1_200)
        XCTAssertNil(MailStore.eligibleForAI(messages, tier: .pro))
        XCTAssertNil(MailStore.eligibleForAI(messages, tier: .max))
    }

    func testAPlanNotYetKnownSortsEverything() {
        // The plan arrives a moment after launch. A first pass before then
        // must not treat a subscriber as free.
        XCTAssertNil(MailStore.eligibleForAI(mailbox(count: 1_200), tier: nil))
    }
}
