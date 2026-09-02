import XCTest
@testable import EmailApp

/// The import screen's wording. The whole point of this type is that it never
/// says something that is not true, so the tests are about exactly that.
final class ImportProgressTests: XCTestCase {

    // MARK: - Honesty

    func testAlmostThereOnlyAppearsWhenItActuallyIs() {
        XCTAssertNotEqual(ImportProgress.importing(done: 10, total: 100).title, "Almost there")
        XCTAssertNotEqual(ImportProgress.importing(done: 50, total: 100).title, "Almost there")
        XCTAssertNotEqual(ImportProgress.importing(done: 84, total: 100).title, "Almost there")
        XCTAssertEqual(ImportProgress.importing(done: 85, total: 100).title, "Almost there")
        XCTAssertEqual(ImportProgress.importing(done: 99, total: 100).title, "Almost there")
    }

    func testTheCountShownIsTheRealCount() {
        XCTAssertEqual(
            ImportProgress.importing(done: 120, total: 480).detail,
            "120 of 480 messages"
        )
    }

    func testWithoutATotalItSaysSoFarRatherThanInventingAFraction() {
        // Gmail does not report how many messages match up front. Showing
        // "0 of 0" or a made-up denominator would be a lie.
        XCTAssertEqual(ImportProgress.importing(done: 30, total: 0).detail, "30 messages so far")
        XCTAssertNil(ImportProgress.importing(done: 30, total: 0).fraction)
    }

    // MARK: - Fraction

    func testFractionTracksTheCounts() {
        XCTAssertEqual(ImportProgress.importing(done: 25, total: 100).fraction, 0.25)
        XCTAssertEqual(ImportProgress.importing(done: 100, total: 100).fraction, 1)
    }

    func testNoFractionBeforeThereIsAnythingToDivide() {
        XCTAssertNil(ImportProgress.idle.fraction)
        XCTAssertNil(ImportProgress.connecting.fraction)
        XCTAssertNil(ImportProgress.counting.fraction)
    }

    // MARK: - Running

    func testRunningCoversEveryWorkingState() {
        XCTAssertTrue(ImportProgress.connecting.isRunning)
        XCTAssertTrue(ImportProgress.counting.isRunning)
        XCTAssertTrue(ImportProgress.importing(done: 1, total: 2).isRunning)
        XCTAssertTrue(ImportProgress.saving.isRunning)
    }

    func testIdleAndFinishedAreNotRunning() {
        // The import screen keys off this. If finished stayed "running" the
        // overlay would never come down.
        XCTAssertFalse(ImportProgress.idle.isRunning)
        XCTAssertFalse(ImportProgress.finished(count: 10, missing: 0).isRunning)
    }

    // MARK: - Every state says something

    func testEveryRunningStateHasWording() {
        let states: [ImportProgress] = [
            .connecting,
            .counting,
            .importing(done: 0, total: 0),
            .importing(done: 5, total: 10),
            .saving,
            .finished(count: 42, missing: 0),
            .finished(count: 1_540, missing: 40),
        ]
        for state in states {
            XCTAssertFalse(state.title.isEmpty, "\(state) has no title")
            XCTAssertFalse(state.detail.isEmpty, "\(state) has no detail")
        }
    }

    func testStartingIsDistinctFromImporting() {
        // Before anything has arrived it should not claim to be importing.
        XCTAssertEqual(ImportProgress.importing(done: 0, total: 200).title, "Starting the import")
        XCTAssertEqual(ImportProgress.importing(done: 20, total: 200).title, "Importing your email")
    }

    func testAPartialImportNeverClaimsToBeComplete() {
        // The whole bug, at the point the user could have seen it: 300 of
        // 1,580 messages, reported as "All set". It must say the number it
        // actually has and the number it was owed.
        let partial = ImportProgress.finished(count: 1_540, missing: 40)
        XCTAssertNotEqual(partial.title, "All set")
        XCTAssertTrue(partial.detail.contains("1540"), partial.detail)
        XCTAssertTrue(partial.detail.contains("1580"), partial.detail)
    }

    func testACleanImportSaysAllSet() {
        let clean = ImportProgress.finished(count: 1_580, missing: 0)
        XCTAssertEqual(clean.title, "All set")
        XCTAssertEqual(clean.detail, "1580 messages ready.")
    }
}
