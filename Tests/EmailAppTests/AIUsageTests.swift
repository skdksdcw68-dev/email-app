import XCTest
@testable import EmailApp

/// Counting what the app asks the AI to do.
///
/// Maily runs on the person's own key, so the bill arrives somewhere else and
/// the app is normally the last to know it ran out -- every AI feature stops
/// at once and nothing says why. These counts are the app's only honest
/// answer to "where did my credit go".
final class AIUsageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AIUsage.reset()
    }

    override func tearDown() {
        AIUsage.reset()
        super.tearDown()
    }

    // MARK: - What each call counts as

    func testActionsAreGroupedByWhatTheyWereFor() {
        // The names people would use, not the plumbing. "ask_stream" means
        // nothing to anybody reading a usage screen.
        XCTAssertEqual(AIUsage.Kind(action: "classify"), .reading)
        XCTAssertEqual(AIUsage.Kind(action: "extract"), .reading)
        XCTAssertEqual(AIUsage.Kind(action: "ask_stream"), .questions)
        XCTAssertEqual(AIUsage.Kind(action: "ask"), .questions)
        XCTAssertEqual(AIUsage.Kind(action: "draft"), .writing)
        XCTAssertEqual(AIUsage.Kind(action: "refine"), .writing)
        XCTAssertEqual(AIUsage.Kind(action: "revise"), .writing)
        XCTAssertEqual(AIUsage.Kind(action: "search"), .searching)
    }

    func testEverythingAutoReplyCountsAsAutoReply() {
        for action in ["autoreply", "autoreply_understanding", "autoreply_example"] {
            XCTAssertEqual(AIUsage.Kind(action: action), .autoReply, action)
        }
    }

    func testAnUnknownActionIsStillCountedSomewhere() {
        // Nothing may be spent without appearing on the screen, including a
        // call added later that nobody remembered to classify here.
        AIUsage.record(action: "something_new")
        XCTAssertEqual(AIUsage.total, 1)
    }

    // MARK: - Counting

    func testCallsAddUp() {
        AIUsage.record(action: "classify")
        AIUsage.record(action: "classify")
        AIUsage.record(action: "ask_stream")

        XCTAssertEqual(AIUsage.count(of: .reading), 2)
        XCTAssertEqual(AIUsage.count(of: .questions), 1)
        XCTAssertEqual(AIUsage.total, 3)
    }

    func testTheBusiestKindComesFirst() {
        AIUsage.record(action: "ask_stream")
        for _ in 0..<5 { AIUsage.record(action: "classify") }

        XCTAssertEqual(AIUsage.used.first?.kind, .reading)
        XCTAssertEqual(AIUsage.used.first?.count, 5)
    }

    func testOnlyWhatWasActuallyUsedIsListed() {
        AIUsage.record(action: "classify")
        XCTAssertEqual(AIUsage.used.map(\.kind), [.reading])
    }

    func testNothingUsedIsAnEmptyList() {
        XCTAssertTrue(AIUsage.used.isEmpty)
        XCTAssertEqual(AIUsage.total, 0)
    }

    func testTheCountSurvivesARelaunch() {
        AIUsage.record(action: "draft")
        // What a cold launch sees: nothing in memory, the count on disk.
        AIUsage.forgetInMemory()
        XCTAssertEqual(AIUsage.count(of: .writing), 1)
    }

    func testResettingClearsIt() {
        AIUsage.record(action: "classify")
        AIUsage.reset()
        XCTAssertEqual(AIUsage.total, 0)
    }

    // MARK: - Which ones are worth worrying about

    func testTheExpensiveKindsAreTheOnesOnTheBigModel() {
        // Reading runs on everything and is the cheap model; a question runs
        // the expensive one up to three times. Somebody looking at a raw
        // count cannot tell that, so the screen marks it.
        XCTAssertTrue(AIUsage.Kind.questions.isExpensive)
        XCTAssertTrue(AIUsage.Kind.writing.isExpensive)
        XCTAssertTrue(AIUsage.Kind.autoReply.isExpensive)
        XCTAssertFalse(AIUsage.Kind.reading.isExpensive)
        XCTAssertFalse(AIUsage.Kind.searching.isExpensive)
    }

    func testEveryKindSaysWhatItIsInPlainWords() {
        for kind in AIUsage.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.detail.isEmpty)
            XCTAssertFalse(kind.title.contains("_"), "no plumbing names: \(kind.title)")
        }
    }
}
