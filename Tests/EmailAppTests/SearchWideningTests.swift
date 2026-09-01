import XCTest
@testable import EmailApp

/// Gmail joins bare words with AND, which is the trap that made a search that
/// ran perfectly find nothing at all.
@MainActor
final class SearchWideningTests: XCTestCase {

    func testTheExactQueryIsTriedFirst() {
        let attempts = MailStore.widening(
            from: "from:upwork welcome", terms: ["upwork", "welcome"], raw: "upwork welcome"
        )
        XCTAssertEqual(attempts.first, "from:upwork welcome")
    }

    func testItFallsBackToAlternativesThenTheStrongestWord() {
        // Five ANDed words demand one email containing all five. The Welcome
        // to Upwork message has neither "registration" nor "created" in it.
        let attempts = MailStore.widening(
            from: "Upwork welcome registration account created",
            terms: ["Upwork", "welcome", "registration", "account", "created"],
            raw: "Upwork welcome registration account created"
        )

        XCTAssertEqual(attempts.count, 3)
        XCTAssertTrue(attempts[1].contains(" OR "), attempts[1])
        // The longest word carries the question.
        XCTAssertEqual(attempts.last, "registration")
    }

    func testShortNoiseWordsAreDropped() {
        let attempts = MailStore.widening(from: nil, terms: [], raw: "my up to date receipt")
        XCTAssertFalse(attempts.contains { $0.contains("up OR") })
    }

    func testASingleWordNeedsNoWidening() {
        let attempts = MailStore.widening(from: "upwork", terms: ["upwork"], raw: "upwork")
        XCTAssertEqual(attempts, ["upwork"])
    }

    func testPunctuationIsStripped() {
        let attempts = MailStore.widening(from: nil, terms: [], raw: "upwork, welcome!")
        XCTAssertTrue(attempts.contains("upwork OR welcome"), attempts.description)
    }
}
