import XCTest
@testable import EmailApp

/// Structure now comes from the model rather than from a keyword table, so
/// this is where the contract between the two is checked.
final class AnswerFencesTests: XCTestCase {

    func testStatsBecomeTiles() {
        let (prose, blocks) = AnswerFences.extract(from: """
        Here is where things stand.

        ```stats
        Very Urgent: 12
        Needs Reply: 8
        Unread: 30
        ```
        """)

        XCTAssertEqual(prose, "Here is where things stand.")
        guard case .stats(let stats)? = blocks.first else {
            return XCTFail("Expected tiles, got \(blocks)")
        }
        XCTAssertEqual(stats.map(\.title), ["Very Urgent", "Needs Reply", "Unread"])
        XCTAssertEqual(stats.map(\.value), ["12", "8", "30"])
    }

    func testATagLabelBorrowsTheTagsOwnChip() {
        // "Very Urgent 12" in an answer should look like "Very Urgent 12" at
        // the top of the inbox.
        let (_, blocks) = AnswerFences.extract(from: "```stats\nVery Urgent: 12\n```")
        guard case .stats(let stats)? = blocks.first else { return XCTFail("no tiles") }
        XCTAssertEqual(stats[0].symbol, AITag.urgent.systemImage)
        XCTAssertEqual(stats[0].tint, AITag.urgent.statTint)
    }

    func testAnUnknownLabelIsStillDrawn() {
        // Refusing to draw a number because the app did not recognise the
        // word would be the old mistake in a smaller costume.
        let (_, blocks) = AnswerFences.extract(from: "```stats\nInvoices overdue: 4\n```")
        guard case .stats(let stats)? = blocks.first else { return XCTFail("no tiles") }
        XCTAssertEqual(stats[0].title, "Invoices overdue")
        XCTAssertEqual(stats[0].value, "4")
    }

    func testOnlyThreeTilesFitARow() {
        let (_, blocks) = AnswerFences.extract(from: """
        ```stats
        A: 1
        B: 2
        C: 3
        D: 4
        ```
        """)
        guard case .stats(let stats)? = blocks.first else { return XCTFail("no tiles") }
        XCTAssertEqual(stats.count, 3)
    }

    func testChartTakesATitleThenPoints() {
        let (prose, blocks) = AnswerFences.extract(from: """
        Newsletters dominate.

        ```chart
        Inbox by tag
        Newsletter: 30
        Important: 12
        Very Urgent: 3
        ```
        """)

        XCTAssertEqual(prose, "Newsletters dominate.")
        guard case .chart(let chart)? = blocks.first else {
            return XCTFail("Expected a chart, got \(blocks)")
        }
        XCTAssertEqual(chart.title, "Inbox by tag")
        XCTAssertEqual(chart.points.map(\.value), [30, 12, 3])
    }

    func testAHalfArrivedFenceIsHeldBackRatherThanShownRaw() {
        // Mid-stream. Showing "```stats" and a stray line to the reader is
        // worse than showing the prose alone for another second.
        let (prose, blocks) = AnswerFences.extract(from: "Where things stand:\n\n```stats\nVery Urgent: 1")
        XCTAssertEqual(prose, "Where things stand:")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testAnEmailFenceIsLeftForTheEmailParser() {
        let text = "Here it is.\n\n```email\nTo: sara@x.com\nSubject: Hi\n\nHello.\n```"
        let (prose, blocks) = AnswerFences.extract(from: text)
        XCTAssertTrue(blocks.isEmpty)
        XCTAssertTrue(prose.contains("```email"), prose)
        XCTAssertNotNil(EmailBlock.extract(from: prose))
    }

    func testProseWithNoFencesIsUntouched() {
        let (prose, blocks) = AnswerFences.extract(from: "Sara confirmed Thursday at 2.")
        XCTAssertEqual(prose, "Sara confirmed Thursday at 2.")
        XCTAssertTrue(blocks.isEmpty)
    }
}
