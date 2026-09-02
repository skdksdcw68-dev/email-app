import XCTest
@testable import EmailApp

/// The check that does not take the model's word for it.
///
/// Everything here is a way for a reply to state something nobody approved.
/// "The prompt says not to" is not a safety mechanism -- a model told never
/// to quote a price will still quote one occasionally, and the whole case for
/// ever letting this send on its own is that something else is checking.
final class AutoReplyVerificationTests: XCTestCase {

    private let approved = """
    Brand: Abel
    What you do: I build iOS apps for early-stage startups.
    Pricing: Projects start at $4,000.
    Hours: Mon–Fri, 9–6.
    """

    private func check(
        _ reply: String,
        boundaries: [String] = [],
        confidence: Double = 0.95
    ) -> AutoReplyVerification {
        AutoReplyVerification.check(
            reply: reply,
            approved: approved,
            boundaries: boundaries,
            confidence: confidence,
            floor: 0.7
        )
    }

    // MARK: - What must pass, or the whole thing is useless

    func testAReplyThatOnlySaysWhatItWasGivenPasses() {
        let verdict = check("""
        Hi Nina,

        Thanks for getting in touch. I build iOS apps for early-stage startups,
        and projects start at $4,000.

        Best,
        Abel
        """)
        XCTAssertTrue(verdict.isClear, "problems: \(verdict.problems)")
    }

    func testAReplyWithNoNumbersAtAllPasses() {
        XCTAssertTrue(check("Hi, thanks for reaching out. I'll come back to you shortly. Best, Abel").isClear)
    }

    func testAnApprovedFigureWrittenDifferentlyStillPasses() {
        // "$4,000" approved, "4000 USD" in the reply. Same number, and
        // holding it back would train somebody to ignore the warnings.
        XCTAssertTrue(check("Projects start at 4000 USD.").isClear)
    }

    // MARK: - Money it was never given

    func testAPriceThatIsNotTheirPriceIsHeldBack() {
        let verdict = check("For this I could do $2,500.")
        XCTAssertFalse(verdict.isClear)
        XCTAssertTrue(verdict.problems.contains { $0.contains("$2,500") }, "\(verdict.problems)")
    }

    func testOtherCurrenciesAreCheckedToo() {
        for amount in ["£3,200", "€1,800", "¥90000"] {
            XCTAssertFalse(check("We could do \(amount).").isClear, amount)
        }
    }

    func testTheSameInventedFigureTwiceIsOneProblem() {
        let verdict = check("It's $2,500. To confirm, $2,500 is the price.")
        XCTAssertEqual(verdict.problems.count, 1, "a reader sees one mistake, not two")
    }

    // MARK: - Dates it committed to

    func testADeadlineNobodyApprovedIsHeldBack() {
        let verdict = check("I'll have it over to you by Friday.")
        XCTAssertFalse(verdict.isClear)
        XCTAssertTrue(verdict.problems.contains { $0.contains("by friday") }, "\(verdict.problems)")
    }

    func testADatedCommitmentIsHeldBack() {
        XCTAssertFalse(check("We'll ship before 14 October.").isClear)
    }

    func testMentioningApprovedHoursIsNotADeadline() {
        // "Mon–Fri, 9–6" is in what they approved, so saying it back is not
        // a commitment they never made.
        XCTAssertTrue(check("I work Mon–Fri, 9–6.").isClear)
    }

    // MARK: - Promises

    func testAGuaranteeIsHeldBack() {
        for promise in ["I guarantee it will work.", "I promise you'll be happy.",
                        "You will receive it shortly."] {
            XCTAssertFalse(check(promise).isClear, promise)
        }
    }

    // MARK: - Boundaries they named

    func testABoundaryWordInTheReplyIsHeldBack() {
        let verdict = check(
            "Happy to look at a discount for you.",
            boundaries: ["Custom or negotiated pricing"]
        )
        XCTAssertFalse(verdict.isClear)
        XCTAssertTrue(verdict.problems.contains { $0.contains("custom or negotiated pricing") },
                      "\(verdict.problems)")
    }

    func testLegalWordsAreHeldBackWhenLegalIsABoundary() {
        let verdict = check(
            "I've reviewed the contract and it looks fine.",
            boundaries: ["Anything legal or contractual"]
        )
        XCTAssertFalse(verdict.isClear)
    }

    func testABoundaryTheyDidNotSetIsNotEnforced() {
        // They said refunds are fine to answer, so the word "refund" in a
        // reply is not a problem. Warning about it would be the app
        // overruling them.
        XCTAssertTrue(check("Refunds take about five days.", boundaries: []).isClear)
    }

    // MARK: - Confidence

    func testLowConfidenceIsHeldBackOnItsOwn() {
        let verdict = check("Thanks, I'll take a look.", confidence: 0.4)
        XCTAssertFalse(verdict.isClear)
        XCTAssertEqual(verdict.confidence, 0.4)
    }

    func testConfidenceIsCarriedThroughEvenWhenItPasses() {
        XCTAssertEqual(check("Thanks, I'll take a look.", confidence: 0.93).confidence, 0.93)
    }

    // MARK: - The shape of the answer

    func testEveryProblemIsASentenceSomebodyCanRead() {
        let verdict = check(
            "I guarantee $2,500 by Friday.",
            boundaries: ["Custom or negotiated pricing"],
            confidence: 0.2
        )
        XCTAssertFalse(verdict.problems.isEmpty)
        for problem in verdict.problems {
            XCTAssertTrue(problem.hasSuffix("."), "problems are sentences: \(problem)")
            XCTAssertFalse(problem.contains("_"), "no codes: \(problem)")
        }
    }

    func testItFailsClosedWhenThereIsNothingApproved() {
        // Somebody who gave Maily no facts at all: any figure in a reply is
        // by definition not one of theirs.
        let verdict = AutoReplyVerification.check(
            reply: "It's $500.",
            approved: "",
            boundaries: [],
            confidence: 0.99,
            floor: 0.7
        )
        XCTAssertFalse(verdict.isClear)
    }
}
