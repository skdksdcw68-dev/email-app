import XCTest
@testable import EmailApp

@MainActor
final class SearchHistoryTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "searches-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testItKeepsWhatWasSearchedFor() {
        let history = SearchHistory(fileURL: fileURL)
        history.record("invoice", mode: .mail, results: 3)

        XCTAssertEqual(history.entries.map(\.text), ["invoice"])
        XCTAssertEqual(history.entries.first?.results, 3)
    }

    func testSearchingAgainMovesItUpRatherThanAddingARow() {
        // A history with "invoice" in it four times is a log, not a shortcut.
        let history = SearchHistory(fileURL: fileURL)
        history.record("invoice", mode: .mail, results: 3)
        history.record("rent", mode: .mail, results: 1)
        history.record("Invoice", mode: .ai, results: 9)

        XCTAssertEqual(history.entries.map(\.text), ["Invoice", "rent"])
        XCTAssertEqual(history.entries.first?.mode, "ai")
        XCTAssertEqual(history.entries.first?.results, 9)
    }

    func testItSurvivesARestart() {
        let history = SearchHistory(fileURL: fileURL)
        history.record("flight confirmation", mode: .ai, results: 2)

        let reloaded = SearchHistory(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.map(\.text), ["flight confirmation"])
        XCTAssertEqual(reloaded.entries.first?.mode, "ai")
    }

    func testAStraySingleCharacterIsNotWorthKeeping() {
        let history = SearchHistory(fileURL: fileURL)
        history.record("a", mode: .mail, results: 0)
        history.record("  ", mode: .mail, results: 0)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testItStopsAtTheLimit() {
        let history = SearchHistory(fileURL: fileURL)
        for index in 0...(SearchHistory.limit + 5) {
            history.record("query \(index)", mode: .mail, results: 1)
        }
        XCTAssertEqual(history.entries.count, SearchHistory.limit)
        // Newest kept, oldest dropped.
        XCTAssertEqual(history.entries.first?.text, "query \(SearchHistory.limit + 5)")
    }

    func testRemovingOneLeavesTheRest() {
        let history = SearchHistory(fileURL: fileURL)
        history.record("invoice", mode: .mail, results: 1)
        history.record("rent", mode: .mail, results: 1)

        guard let target = history.entries.first(where: { $0.text == "invoice" }) else {
            return XCTFail("expected the entry")
        }
        history.remove(target.id)

        XCTAssertEqual(history.entries.map(\.text), ["rent"])
    }

    func testClearingEmptiesItAndTheFile() {
        let history = SearchHistory(fileURL: fileURL)
        history.record("invoice", mode: .mail, results: 1)
        history.clearAll()

        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(SearchHistory(fileURL: fileURL).entries.isEmpty)
    }

    func testDisconnectingTheMailboxWipesIt() async {
        // It holds what was typed, which names people. It goes with the mail.
        let history = SearchHistory(fileURL: fileURL)
        history.record("invoice from Sara", mode: .mail, results: 1)

        NotificationCenter.default.post(name: .mailboxDisconnected, object: nil)

        for _ in 0..<20 where !history.entries.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(history.entries.isEmpty)
    }
}
