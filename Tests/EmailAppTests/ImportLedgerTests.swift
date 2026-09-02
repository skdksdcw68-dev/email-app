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

/// The trap that let a mailbox stay permanently short.
///
/// `hasImported` was set the moment anything landed, so the import never ran
/// again; and the ledger that knew what was still owed was thrown away the
/// moment its ids aged out of the window. Between the two, an account that
/// lost most of a first import stayed that way for good -- and the assistant
/// was then asked to search a mailbox with the evidence removed.
final class ImportAuditTests: XCTestCase {

    func testAnAuditReportsWhatIsHeldAgainstWhatGmailHas() {
        let audit = MailStore.ImportAudit(expected: 1580, missing: 1300)
        XCTAssertEqual(audit.held, 280)
        XCTAssertFalse(audit.isComplete)
    }

    func testNothingMissingReadsAsComplete() {
        let audit = MailStore.ImportAudit(expected: 1580, missing: 0)
        XCTAssertEqual(audit.held, 1580)
        XCTAssertTrue(audit.isComplete)
    }

    func testALedgerBuiltFromWhatIsMissingCountsTheWholeWindow() {
        // What `verifyAgainstGmail` builds: the denominator is everything
        // Gmail listed, not just the shortfall, so the screen reads
        // "280 of 1,580" rather than "0 of 1,300".
        let ledger = ImportLedger(pending: Array(repeating: "id", count: 1300), done: 280, total: 1580)
        XCTAssertEqual(ledger.total, 1580)
        XCTAssertEqual(ledger.done, 280)
        XCTAssertFalse(ledger.isComplete)
    }

    func testAStaleLedgerIsNoLongerTheEndOfTheStory() {
        // Stale still means its ids cannot be trusted -- the window moved --
        // but the response is now to re-count against Gmail rather than to
        // clear it and stop.
        let old = ImportLedger(
            pending: ["a"], done: 0, total: 1,
            startedAt: Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        XCTAssertTrue(old.isStale)

        let fresh = ImportLedger(pending: ["a"], done: 0, total: 1)
        XCTAssertFalse(fresh.isStale)
    }
}
