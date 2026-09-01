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

    // MARK: - Showing emails

    private let numbered: [Message] = (1...5).map { n in
        Message(sender: Contact(name: "Sender \(n)", address: "s\(n)@x.com"),
                recipients: [], subject: "Subject \(n)", body: "-",
                date: .now.addingTimeInterval(Double(-n)), mailbox: .inbox)
    }

    func testAShowBlockBecomesTheEmailItself() {
        // "The last email I got" is one sentence and the card, not a
        // paragraph spelling out the sender, subject and time of an email
        // that is one tap away.
        let (prose, blocks) = AnswerFences.extract(
            from: "Your last email is from Sender 1.\n\n```show\n1\n```",
            messages: numbered
        )
        XCTAssertEqual(prose, "Your last email is from Sender 1.")
        guard case .messages(let shown)? = blocks.first else {
            return XCTFail("Expected a message card, got \(blocks)")
        }
        XCTAssertEqual(shown.map(\.subject), ["Subject 1"])
    }

    func testSeveralNumbersKeepTheModelsOrder() {
        let (_, blocks) = AnswerFences.extract(from: "```show\n4\n2\n```", messages: numbered)
        guard case .messages(let shown)? = blocks.first else { return XCTFail("no list") }
        XCTAssertEqual(shown.map(\.subject), ["Subject 4", "Subject 2"])
    }

    func testCommasAndDecorationAreForgiven() {
        // Told one per line; given "[1], 3." anyway. The reader should not
        // pay for the model's punctuation.
        let (_, blocks) = AnswerFences.extract(from: "```show\n[1], 3.\n```", messages: numbered)
        guard case .messages(let shown)? = blocks.first else { return XCTFail("no list") }
        XCTAssertEqual(shown.map(\.subject), ["Subject 1", "Subject 3"])
    }

    func testOnlyTheFirstNumberOnALineCounts() {
        // "3. Sender, 10:31" is message three. Reading 10 and 31 out of it
        // would show two emails nobody asked about, or nothing.
        let (_, blocks) = AnswerFences.extract(from: "```show\n3. Sender 3 at 10:31\n```", messages: numbered)
        guard case .messages(let shown)? = blocks.first else { return XCTFail("no list") }
        XCTAssertEqual(shown.map(\.subject), ["Subject 3"])
    }

    func testOutOfRangeAndRepeatsAreDropped() {
        let (_, blocks) = AnswerFences.extract(from: "```show\n0\n9\n2\n2\n```", messages: numbered)
        guard case .messages(let shown)? = blocks.first else { return XCTFail("no list") }
        XCTAssertEqual(shown.map(\.subject), ["Subject 2"])
    }

    func testNothingInRangeMeansNoBlock() {
        let (prose, blocks) = AnswerFences.extract(from: "Here.\n\n```show\n12\n```", messages: numbered)
        XCTAssertEqual(prose, "Here.")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testAShowBlockWithNoMessagesToPointAtIsDropped() {
        let (prose, blocks) = AnswerFences.extract(from: "Here.\n\n```show\n1\n```")
        XCTAssertEqual(prose, "Here.")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testAHalfStreamedShowBlockIsHeldBack() {
        let (prose, blocks) = AnswerFences.extract(from: "Your last email:\n\n```sh", messages: numbered)
        XCTAssertEqual(prose, "Your last email:")
        XCTAssertTrue(blocks.isEmpty)
    }
}
