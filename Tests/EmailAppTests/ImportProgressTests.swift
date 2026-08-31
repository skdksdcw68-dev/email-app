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
        XCTAssertFalse(ImportProgress.finished.isRunning)
    }

    // MARK: - Every state says something

    func testEveryRunningStateHasWording() {
        let states: [ImportProgress] = [
            .connecting,
            .counting,
            .importing(done: 0, total: 0),
            .importing(done: 5, total: 10),
            .saving,
            .finished,
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
}
