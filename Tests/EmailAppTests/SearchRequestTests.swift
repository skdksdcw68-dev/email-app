import XCTest
@testable import EmailApp

/// The one line the model uses to ask for a search instead of answering.
final class SearchRequestTests: XCTestCase {

    func testASingleQueryStillWorks() {
        XCTAssertEqual(SearchRequest.extract(from: "SEARCH: upwork welcome"), ["upwork welcome"])
    }

    func testAlternativesComeBackInOrder() {
        // The point of the whole change: one guess at the wording is a guess,
        // and Gmail ANDs words so a slightly wrong guess returns nothing.
        let hypotheses = SearchRequest.extract(
            from: "SEARCH: upwork welcome | welcome to upwork | joined upwork"
        )
        XCTAssertEqual(hypotheses, ["upwork welcome", "welcome to upwork", "joined upwork"])
    }

    func testQuotesAndTrailingPunctuationAreStripped() {
        let hypotheses = SearchRequest.extract(from: "SEARCH: \"upwork welcome\" | 'joined upwork'.")
        XCTAssertEqual(hypotheses, ["upwork welcome", "joined upwork"])
    }

    func testRepeatsAreDroppedRatherThanSearchedTwice() {
        // Each alternative is a request. Paying twice for the same one is
        // the model's mistake and the app should not forward it.
        let hypotheses = SearchRequest.extract(from: "SEARCH: upwork | Upwork | upwork welcome")
        XCTAssertEqual(hypotheses, ["upwork", "upwork welcome"])
    }

    func testItStopsAtFour() {
        let hypotheses = SearchRequest.extract(from: "SEARCH: a1 | b2 | c3 | d4 | e5 | f6")
        XCTAssertEqual(hypotheses.count, SearchRequest.maxHypotheses)
    }

    func testOnlyTheFirstLineCounts() {
        // The model was told the line and nothing else. If it explains
        // itself underneath anyway, the explanation is not a query.
        let hypotheses = SearchRequest.extract(from: "SEARCH: upwork welcome\nI will look for that.")
        XCTAssertEqual(hypotheses, ["upwork welcome"])
    }

    func testAnAnswerIsNotASearchRequest() {
        XCTAssertTrue(SearchRequest.extract(from: "Your account was created in March.").isEmpty)
        XCTAssertFalse(SearchRequest.isRequest("I searched for it already."))
    }

    func testAMarkerWithNothingBehindItIsIgnored() {
        // Rather than searching Gmail for an empty string.
        XCTAssertTrue(SearchRequest.extract(from: "SEARCH:").isEmpty)
        XCTAssertTrue(SearchRequest.extract(from: "SEARCH: | | ").isEmpty)
    }
}

/// Steps exist so the reader can see the work. These check the one property
/// that makes them worth showing: they cannot describe work that did not
/// happen, because nothing is allowed to pass a count in.
final class TaskStepTests: XCTestCase {

    private func message(_ subject: String) -> Message {
        Message(sender: Contact(name: "A", address: "a@x.com"), recipients: [],
                subject: subject, body: "-", date: .now, mailbox: .inbox)
    }

    func testASearchStepCountsItsOwnResults() {
        let step = TaskStep.searched("upwork welcome", found: [message("one"), message("two")])
        XCTAssertTrue(step.detail.contains("2 emails"), step.detail)
        XCTAssertTrue(step.detail.contains("upwork welcome"), step.detail)
    }

    func testAnEmptySearchSaysSoRatherThanGoingQuiet() {
        // "Searched X, nothing" is what makes a later "I could not find it"
        // read as looked-and-missed instead of never-checked.
        let step = TaskStep.searched("linkedin welcome", found: [])
        XCTAssertTrue(step.detail.contains("nothing"), step.detail)
    }

    func testOneResultIsSingular() {
        XCTAssertTrue(TaskStep.searched("q", found: [message("one")]).detail.contains("1 email"))
        XCTAssertTrue(TaskStep.reading([message("one")]).detail.contains("1 email"))
    }

    func testTheSummaryCountsStepsAndSearches() {
        let steps = [
            TaskStep.understanding(),
            TaskStep.searched("a", found: []),
            TaskStep.searched("b", found: [message("x")]),
            TaskStep.reading([message("x")]),
        ]
        XCTAssertEqual(TaskStep.summary(of: steps), "4 steps \u{00B7} 2 searches")
    }

    func testASummaryWithNoSearchesDoesNotMentionThem() {
        XCTAssertEqual(TaskStep.summary(of: [.writing(to: "Sara")]), "1 step")
        XCTAssertEqual(TaskStep.summary(of: []), "")
    }

    func testStepsStartOpenAndAreClosedByTheCaller() {
        // The open one is what pulses. A step that arrived already finished
        // would never show as running.
        XCTAssertFalse(TaskStep.understanding().isDone)
    }
}
