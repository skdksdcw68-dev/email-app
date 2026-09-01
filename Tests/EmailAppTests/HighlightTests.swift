import XCTest
import SwiftUI
@testable import EmailApp

/// Marking the matched words is what turns a list of results into a list of
/// reasons, so the matching has to be right in the awkward cases.
final class HighlightTests: XCTestCase {

    private func markedRanges(_ text: String, _ terms: [String]) -> [String] {
        let attributed = Highlight.mark(text, terms: terms)
        return attributed.runs.compactMap { run in
            run.backgroundColor == nil ? nil : String(attributed[run.range].characters)
        }
    }

    func testItMarksTheTerm() {
        XCTAssertEqual(markedRanges("Invoice for March", ["invoice"]), ["Invoice"])
    }

    func testMatchingIgnoresCaseAndAccents() {
        XCTAssertEqual(markedRanges("Meeting at the Café", ["cafe"]), ["Café"])
    }

    func testEveryOccurrenceIsMarked() {
        // The loop has to walk forward past each hit, or only the first is
        // ever found.
        XCTAssertEqual(markedRanges("invoice, invoice, invoice", ["invoice"]).count, 3)
    }

    func testSeveralTermsAreAllMarked() {
        let marked = markedRanges("Invoice from Sara", ["invoice", "sara"])
        XCTAssertEqual(Set(marked), ["Invoice", "Sara"])
    }

    func testNothingToMarkLeavesTheTextAlone() {
        XCTAssertTrue(markedRanges("Invoice for March", []).isEmpty)
        XCTAssertTrue(markedRanges("Invoice for March", ["rent"]).isEmpty)
    }

    func testASingleLetterIsNotATerm() {
        // Marking every "a" in a result would light up the whole row.
        XCTAssertTrue(markedRanges("A note about a thing", ["a"]).isEmpty)
    }

    func testATermAtTheVeryEndDoesNotRunOff() {
        // The walk forward has to stop at the end of the string rather than
        // stepping past it.
        XCTAssertEqual(markedRanges("Paid the invoice", ["invoice"]), ["invoice"])
    }

    // MARK: - Terms from a typed query

    func testTermsDropTheNoiseWords() {
        XCTAssertEqual(Highlight.terms(in: "the invoice from Sara"), ["invoice", "Sara"])
    }

    func testTermsHandlePunctuation() {
        XCTAssertEqual(Highlight.terms(in: "renewal, urgent!"), ["renewal", "urgent"])
    }

    func testAQueryOfOnlyNoiseYieldsNoTerms() {
        XCTAssertTrue(Highlight.terms(in: "the email about that").isEmpty)
    }
}
