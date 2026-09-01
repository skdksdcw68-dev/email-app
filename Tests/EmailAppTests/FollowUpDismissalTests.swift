import XCTest
@testable import EmailApp

/// A list that cannot be cleared stops being a list and becomes wallpaper,
/// so dismissal has to stick. It also has to un-stick when the situation
/// changes, which is the part that is easy to get wrong.
@MainActor
final class FollowUpDismissalTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FollowUpPreferences.clearAll()
    }

    override func tearDown() {
        FollowUpPreferences.clearAll()
        super.tearDown()
    }

    func testDismissingHidesIt() {
        let sent = Date.now.addingTimeInterval(-60)
        XCTAssertFalse(FollowUpPreferences.isDismissed("thread-1", lastActivity: sent))

        FollowUpPreferences.dismiss("thread-1")
        XCTAssertTrue(FollowUpPreferences.isDismissed("thread-1", lastActivity: sent))
    }

    func testItComesBackWhenTheConversationMovesAgain() {
        // They finally replied, or another chase went out. That is a new
        // situation, not the one that was waved away.
        FollowUpPreferences.dismiss("thread-1")
        let later = Date.now.addingTimeInterval(60)
        XCTAssertFalse(FollowUpPreferences.isDismissed("thread-1", lastActivity: later))
    }

    func testDismissingOneLeavesTheRestAlone() {
        FollowUpPreferences.dismiss("thread-1")
        XCTAssertFalse(
            FollowUpPreferences.isDismissed("thread-2", lastActivity: .now.addingTimeInterval(-60))
        )
    }

    func testRestoringUndoesIt() {
        let sent = Date.now.addingTimeInterval(-60)
        FollowUpPreferences.dismiss("thread-1")
        FollowUpPreferences.restore("thread-1")
        XCTAssertFalse(FollowUpPreferences.isDismissed("thread-1", lastActivity: sent))
    }

    func testTheStoreHidesDismissedFollowUps() {
        let store = MailStore.connected()
        let before = store.followUps
        guard let first = before.first else {
            return XCTFail("The sample mailbox should have follow-ups")
        }

        store.dismissFollowUp(first.id)

        XCTAssertEqual(store.followUps.count, before.count - 1)
        XCTAssertFalse(store.followUps.contains { $0.id == first.id })
    }
}
