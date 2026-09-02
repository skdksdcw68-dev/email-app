import XCTest
@testable import EmailApp

/// The import used to lose a mailbox quietly: one failed request broke the
/// loop, `hasImported = true` was written anyway, and nothing ever went back.
/// These are the properties that make that impossible.
final class ImportLedgerTests: XCTestCase {

    override func tearDown() {
        ImportLedger.clear()
        super.tearDown()
    }

    func testTheTotalIsKnownBeforeAnythingIsFetched() {
        // The old bar guessed its denominator from the page size, so it could
        // sit at 100% with a thousand messages still to come.
        let ledger = ImportLedger(pending: ["a", "b", "c"])
        XCTAssertEqual(ledger.total, 3)
        XCTAssertEqual(ledger.done, 0)
    }

    func testDoneAndPendingAlwaysAccountForTheWholeMailbox() {
        var ledger = ImportLedger(pending: ["a", "b", "c", "d"])
        ledger.complete(["a", "b"])
        XCTAssertEqual(ledger.done, 2)
        XCTAssertEqual(ledger.pending, ["c", "d"])
        XCTAssertEqual(ledger.done + ledger.pending.count, ledger.total)
    }

    func testCompletingSomethingTwiceDoesNotInflateTheCount() {
        // A retried chunk must not make the app believe it has more mail than
        // Gmail listed.
        var ledger = ImportLedger(pending: ["a", "b"])
        ledger.complete(["a"])
        ledger.complete(["a"])
        XCTAssertEqual(ledger.done, 1)
        XCTAssertEqual(ledger.pending, ["b"])
    }

    func testARefusedChunkGoesToTheBackAndStaysOwed() {
        // The bug in one line: a chunk that would not come used to end the
        // whole import. It should cost its own place in the queue, nothing
        // more, and it must still be owed afterwards.
        var ledger = ImportLedger(pending: ["a", "b", "c", "d"])
        ledger.postpone(["a", "b"])
        XCTAssertEqual(ledger.pending, ["c", "d", "a", "b"])
        XCTAssertEqual(ledger.done, 0)
        XCTAssertFalse(ledger.isComplete)
    }

    func testItIsOnlyCompleteWhenNothingIsOwed() {
        var ledger = ImportLedger(pending: ["a"])
        XCTAssertFalse(ledger.isComplete)
        ledger.complete(["a"])
        XCTAssertTrue(ledger.isComplete)
    }

    func testItSurvivesBeingKilled() {
        var ledger = ImportLedger(pending: ["a", "b", "c"])
        ledger.complete(["a"])
        ledger.save()

        let resumed = ImportLedger.load()
        XCTAssertEqual(resumed?.pending, ["b", "c"])
        XCTAssertEqual(resumed?.done, 1)
        XCTAssertEqual(resumed?.total, 3)
    }

    func testAWeekOldLedgerIsStale() {
        // The three month window has moved on, so those ids are the wrong
        // ids. Resuming against them would fetch mail that has aged out and
        // still miss what came in.
        let old = ImportLedger(
            pending: ["a"], done: 0, total: 1,
            startedAt: .now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        XCTAssertTrue(old.isStale)
        XCTAssertFalse(ImportLedger(pending: ["a"]).isStale)
    }

    func testChunksComeOffTheFrontInOrder() {
        let ledger = ImportLedger(pending: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(ledger.nextChunk(2), ["a", "b"])
        XCTAssertNil(ImportLedger(pending: []).nextChunk(2))
    }

    func testAShortMailboxTakesOneChunk() {
        let ledger = ImportLedger(pending: ["a"])
        XCTAssertEqual(ledger.nextChunk(50), ["a"])
    }
}
