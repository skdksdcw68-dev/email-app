import XCTest
@testable import EmailApp

/// The one line the model uses to ask for a look instead of answering.
final class SearchRequestTests: XCTestCase {

    func testASingleQueryStillWorks() {
        let request = SearchRequest.extract(from: "SEARCH: upwork welcome")
        XCTAssertEqual(request?.kind, .wording)
        XCTAssertEqual(request?.queries, ["upwork welcome"])
    }

    func testAlternativesComeBackInOrder() {
        // The point of the whole change: one guess at the wording is a guess,
        // and Gmail ANDs words so a slightly wrong guess returns nothing.
        let request = SearchRequest.extract(
            from: "SEARCH: upwork welcome | welcome to upwork | joined upwork"
        )
        XCTAssertEqual(request?.queries, ["upwork welcome", "welcome to upwork", "joined upwork"])
    }

    func testOldestIsItsOwnKindOfRequest() {
        // "When did I join LinkedIn" is not a wording problem. The welcome is
        // under eight years of notifications and Gmail returns newest first,
        // so the model has to be able to ask for the other end.
        let request = SearchRequest.extract(from: "OLDEST: from:linkedin | from:instagram")
        XCTAssertEqual(request?.kind, .earliest)
        XCTAssertEqual(request?.queries, ["from:linkedin", "from:instagram"])
    }

    func testGmailOperatorsSurviveIntact() {
        // "from:twitter OR from:x.com" is one query with a space in it, and
        // the colon and the dot are part of it. Only "|" separates.
        let request = SearchRequest.extract(from: "OLDEST: from:twitter OR from:x.com | upwork")
        XCTAssertEqual(request?.queries, ["from:twitter OR from:x.com", "upwork"])
    }

    func testQuotesAndTrailingPunctuationAreStripped() {
        let request = SearchRequest.extract(from: "SEARCH: \"upwork welcome\" | 'joined upwork'.")
        XCTAssertEqual(request?.queries, ["upwork welcome", "joined upwork"])
    }

    func testRepeatsAreDroppedRatherThanSearchedTwice() {
        // Each alternative is a request. Paying twice for the same one is
        // the model's mistake and the app should not forward it.
        let request = SearchRequest.extract(from: "SEARCH: upwork | Upwork | upwork welcome")
        XCTAssertEqual(request?.queries, ["upwork", "upwork welcome"])
    }

    func testItStopsAtFour() {
        let request = SearchRequest.extract(from: "SEARCH: a1 | b2 | c3 | d4 | e5 | f6")
        XCTAssertEqual(request?.queries.count, SearchRequest.maxHypotheses)
    }

    func testOnlyTheFirstLineCounts() {
        // The model was told the line and nothing else. If it explains
        // itself underneath anyway, the explanation is not a query.
        let request = SearchRequest.extract(from: "SEARCH: upwork welcome\nI will look for that.")
        XCTAssertEqual(request?.queries, ["upwork welcome"])
    }

    func testAnAnswerIsNotASearchRequest() {
        XCTAssertNil(SearchRequest.extract(from: "Your account was created in March."))
        XCTAssertFalse(SearchRequest.isRequest("I searched for it already."))
        XCTAssertFalse(SearchRequest.isRequest("Oldest first, here they are."))
    }

    func testAMarkerWithNothingBehindItIsIgnored() {
        // Rather than searching Gmail for an empty string.
        XCTAssertNil(SearchRequest.extract(from: "SEARCH:"))
        XCTAssertNil(SearchRequest.extract(from: "SEARCH: | | "))
        XCTAssertNil(SearchRequest.extract(from: "OLDEST:"))
    }

    // MARK: - Holding the stream

    func testTheStreamIsHeldWhileItCouldStillBeARequest() {
        // "SEARCH: upwork welcome" was visible for the second before the
        // search replaced it. The first letters of a marker are held back.
        XCTAssertTrue(SearchRequest.couldBecomeRequest(""))
        XCTAssertTrue(SearchRequest.couldBecomeRequest("S"))
        XCTAssertTrue(SearchRequest.couldBecomeRequest("SEARCH"))
        XCTAssertTrue(SearchRequest.couldBecomeRequest("SEARCH: upwork"))
        XCTAssertTrue(SearchRequest.couldBecomeRequest("OLD"))
        XCTAssertTrue(SearchRequest.couldBecomeRequest("\nOLDEST: from:linkedin"))
    }

    func testProseIsReleasedAsSoonAsItCannotBeARequest() {
        // One token in, "Su" is not the start of any marker, and holding a
        // real answer back any longer is the stream looking stuck.
        XCTAssertFalse(SearchRequest.couldBecomeRequest("Su"))
        XCTAssertFalse(SearchRequest.couldBecomeRequest("Your last"))
        XCTAssertFalse(SearchRequest.couldBecomeRequest("Search results show"))
    }
}

/// Steps exist so the reader can see the work. These check the one property
/// that makes them worth showing: they cannot describe work that did not
/// happen, because nothing is allowed to pass a count in.
final class TaskStepTests: XCTestCase {

    private func message(_ subject: String, daysAgo: Int = 0) -> Message {
        Message(sender: Contact(name: "A", address: "a@x.com"), recipients: [],
                subject: subject, body: "-",
                date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
                mailbox: .inbox)
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

    func testGoingBackReportsTheOldestDateItActuallyFound() {
        // The date on the step is read off the oldest message. There is no
        // way to write "2019" on it without a message from 2019.
        let old = message("Welcome to LinkedIn", daysAgo: 2000)
        let step = TaskStep.wentBack("from:linkedin", found: [message("newer", daysAgo: 30), old], reachedStart: true)
        let expected = old.date.formatted(date: .abbreviated, time: .omitted)
        XCTAssertTrue(step.detail.contains(expected), step.detail)
        XCTAssertFalse(step.detail.contains("older"), step.detail)
    }

    func testGoingBackAdmitsWhenItDidNotReachTheStart() {
        // Hitting the ceiling is not the same as reaching the beginning, and
        // the step says so rather than letting "you joined in 2022" stand.
        let step = TaskStep.wentBack("from:linkedin", found: [message("x", daysAgo: 900)], reachedStart: false)
        XCTAssertTrue(step.detail.contains("older"), step.detail)
    }

    func testGoingBackAndFindingNothingSaysNothing() {
        XCTAssertTrue(TaskStep.wentBack("from:nobody", found: [], reachedStart: true).detail.contains("nothing"))
    }

    func testUnreachableIsNotNothing() {
        // A request that failed did not look. Saying "nothing" would let the
        // model tell somebody their mail does not have it.
        let step = TaskStep.unreachable("from:linkedin")
        XCTAssertFalse(step.detail.contains("nothing"), step.detail)
        XCTAssertTrue(step.detail.contains("Could not reach"), step.detail)
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
        XCTAssertFalse(TaskStep.rethinking().isDone)
    }
}
