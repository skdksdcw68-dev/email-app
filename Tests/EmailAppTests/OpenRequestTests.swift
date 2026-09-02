import XCTest
@testable import EmailApp

/// The verb that lets the model read a message it can already see.
///
/// The digest carries the opening of each email, which says what a message
/// is and not what it asks for -- the request is usually in the last
/// paragraph, after the context explaining it. Before this, an answer that
/// needed the bottom of an email could not be given at all: searching finds
/// the message the model is already holding.
final class OpenRequestTests: XCTestCase {

    func testAnOpenRequestIsRecognised() {
        let request = SearchRequest.extract(from: "OPEN: 3")
        XCTAssertEqual(request?.kind, .opening)
        XCTAssertEqual(request?.numbers(within: 10), [3])
    }

    func testItDoesNotAskGmailForAnythingItAlreadyHas() {
        XCTAssertFalse(SearchRequest.Kind.opening.needsGmail)
        XCTAssertTrue(SearchRequest.Kind.wording.needsGmail)
        XCTAssertTrue(SearchRequest.Kind.earliest.needsGmail)
    }

    func testSeveralNumbersInEitherSeparator() {
        XCTAssertEqual(SearchRequest.extract(from: "OPEN: 1 | 4 | 7")?.numbers(within: 10), [1, 4, 7])
        XCTAssertEqual(SearchRequest.extract(from: "OPEN: 2, 5")?.numbers(within: 10), [2, 5])
    }

    func testOnlyTheFirstNumberInAPieceCounts() {
        // "3. the invoice from 2024" is message three, not three and 2024.
        XCTAssertEqual(SearchRequest.extract(from: "OPEN: 3. the invoice from 2024")?.numbers(within: 10), [3])
    }

    func testNumbersOutsideTheListAreDropped() {
        // A model that asks for ninety when it was shown twelve has
        // miscounted. Inventing a message to satisfy it would be worse.
        XCTAssertEqual(SearchRequest.extract(from: "OPEN: 90 | 2")?.numbers(within: 12), [2])
        XCTAssertEqual(SearchRequest.extract(from: "OPEN: 0")?.numbers(within: 12), [])
    }

    func testRepeatsAreAskedForOnce() {
        XCTAssertEqual(SearchRequest.extract(from: "OPEN: 3 | 3 | 3")?.numbers(within: 10), [3])
    }

    func testItCannotAskForTheWholeDigest() {
        let many = (1...20).map(String.init).joined(separator: " | ")
        let opened = SearchRequest.extract(from: "OPEN: \(many)")?.numbers(within: 40)
        XCTAssertEqual(opened?.count, SearchRequest.maxOpened)
    }

    func testNothingToOpenWhenThereAreNoMessages() {
        XCTAssertEqual(SearchRequest.extract(from: "OPEN: 1")?.numbers(within: 0), [])
    }

    func testASearchRequestYieldsNoNumbers() {
        XCTAssertEqual(SearchRequest.extract(from: "SEARCH: upwork welcome")?.numbers(within: 10), [])
    }

    func testTheVerbIsHeldBackWhileItStreams() {
        // The reader must never see "OPEN:" arrive, the same as the other two.
        for partial in ["O", "OP", "OPEN", "OPEN:"] {
            XCTAssertTrue(SearchRequest.couldBecomeRequest(partial), partial)
        }
        XCTAssertFalse(SearchRequest.couldBecomeRequest("Opening hours are"))
    }

    func testProseIsStillProse() {
        XCTAssertNil(SearchRequest.extract(from: "You opened the invoice on Tuesday."))
    }
}
