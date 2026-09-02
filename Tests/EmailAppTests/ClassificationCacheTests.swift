import XCTest
@testable import EmailApp

/// The cache that stops the app paying twice to read the same email.
///
/// It is now held in memory and written a batch at a time, which is worth
/// testing precisely because getting it wrong is invisible: nothing breaks,
/// the app just quietly re-classifies a mailbox it had already read.
final class ClassificationCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ClassificationCache.clear()
    }

    override func tearDown() {
        ClassificationCache.clear()
        super.tearDown()
    }

    private func classification(
        _ summary: String, priority: String = "urgent", extract: Bool? = nil
    ) -> AIService.Classification {
        AIService.Classification(
            priority: priority,
            needsReply: true,
            summary: summary,
            category: "other",
            extract: extract
        )
    }

    func testWhatIsStoredCanBeReadStraightBack() {
        ClassificationCache.store(classification("Wants the quote"), for: "m1")

        let entry = ClassificationCache.entry(for: "m1")
        XCTAssertEqual(entry?.summary, "Wants the quote")
        XCTAssertEqual(entry?.priority, "urgent")
        XCTAssertNil(ClassificationCache.entry(for: "m2"))
    }

    func testTheSecondTierFlagSurvivesTheRoundTrip() {
        // This decides whether an email gets the deeper read, so losing it
        // means paying for a classification that then does nothing.
        ClassificationCache.store(classification("Asks for something", extract: true), for: "m1")
        ClassificationCache.store(classification("A newsletter", extract: false), for: "m2")

        XCTAssertEqual(ClassificationCache.entry(for: "m1")?.extract, true)
        XCTAssertEqual(ClassificationCache.entry(for: "m2")?.extract, false)
    }

    func testStoringDoesNotWriteUntilItIsFlushed() {
        ClassificationCache.store(classification("Held"), for: "m1")
        XCTAssertNil(UserDefaults.standard.data(forKey: "ai.classifications"))

        ClassificationCache.flush()
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "ai.classifications"))
    }

    func testAFlushedEntryComesBackOnTheNextLaunch() {
        ClassificationCache.store(classification("Kept"), for: "m1")
        ClassificationCache.flush()

        // What a cold launch sees: nothing in memory, everything on disk.
        ClassificationCache.forgetInMemory()

        XCTAssertEqual(ClassificationCache.entry(for: "m1")?.summary, "Kept")
    }

    func testAnUnflushedEntryIsTheOnlyThingLostToAKill() {
        ClassificationCache.store(classification("Saved"), for: "m1")
        ClassificationCache.flush()
        ClassificationCache.store(classification("Lost"), for: "m2")

        ClassificationCache.forgetInMemory()

        XCTAssertEqual(ClassificationCache.entry(for: "m1")?.summary, "Saved")
        XCTAssertNil(ClassificationCache.entry(for: "m2"))
    }

    func testFlushingTwiceIsNotTwoWrites() {
        ClassificationCache.store(classification("One"), for: "m1")
        ClassificationCache.flush()
        let first = UserDefaults.standard.data(forKey: "ai.classifications")

        ClassificationCache.flush()
        XCTAssertEqual(UserDefaults.standard.data(forKey: "ai.classifications"), first)
    }

    func testClearingEmptiesMemoryAndDisk() {
        ClassificationCache.store(classification("Gone"), for: "m1")
        ClassificationCache.flush()

        ClassificationCache.clear()

        XCTAssertNil(ClassificationCache.entry(for: "m1"))
        XCTAssertNil(UserDefaults.standard.data(forKey: "ai.classifications"))
        // And a clear must not be undone by a later flush of what it cleared.
        ClassificationCache.flush()
        XCTAssertNil(UserDefaults.standard.data(forKey: "ai.classifications"))
    }

    func testTheOldestGoFirstOnceItIsFull() {
        for index in 0...520 {
            ClassificationCache.store(classification("Summary \(index)"), for: "m\(index)")
        }

        // The newest are all still there; something from the start is not.
        XCTAssertNotNil(ClassificationCache.entry(for: "m520"))
        XCTAssertNotNil(ClassificationCache.entry(for: "m400"))
        XCTAssertNil(ClassificationCache.entry(for: "m0"))
    }
}
