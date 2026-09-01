import XCTest
@testable import EmailApp

/// The top of the assistant's decision ladder. Each of these is a case that
/// used to go wrong: "hi" answered with a list of tagged mail, "send it"
/// treated as a question, a request to reply treated as a question about
/// replying.
final class ChatIntentTests: XCTestCase {

    // MARK: - Greetings

    func testAGreetingIsAGreeting() {
        XCTAssertEqual(ChatIntentParser.parse("hi", hasPendingDraft: false), .greeting(.hello))
        XCTAssertEqual(ChatIntentParser.parse("Hi there!", hasPendingDraft: false), .greeting(.hello))
    }

    func testAGreetingWithFillerIsStillAGreeting() {
        XCTAssertEqual(ChatIntentParser.parse("Hey Maily!", hasPendingDraft: false), .greeting(.hello))
        XCTAssertEqual(ChatIntentParser.parse("thanks a lot", hasPendingDraft: false), .greeting(.thanks))
        XCTAssertEqual(ChatIntentParser.parse("ok", hasPendingDraft: false), .greeting(.acknowledgement))
    }

    func testAGreetingFollowedByARealQuestionIsNotAGreeting() {
        XCTAssertEqual(
            ChatIntentParser.parse("hey what needs a reply", hasPendingDraft: false),
            .question
        )
    }

    // MARK: - A waiting draft

    func testSendOnlyMeansSendWhileADraftIsWaiting() {
        XCTAssertEqual(ChatIntentParser.parse("send it", hasPendingDraft: true), .sendPendingDraft)
        XCTAssertEqual(ChatIntentParser.parse("Yes", hasPendingDraft: true), .sendPendingDraft)
        // With nothing waiting, "send it" is not an instruction to anything.
        XCTAssertEqual(ChatIntentParser.parse("send it", hasPendingDraft: false), .question)
    }

    func testNoMeansDiscardWhileADraftIsWaiting() {
        XCTAssertEqual(ChatIntentParser.parse("no", hasPendingDraft: true), .discardPendingDraft)
        XCTAssertEqual(ChatIntentParser.parse("don't send", hasPendingDraft: true), .discardPendingDraft)
    }

    // MARK: - Draft requests

    func testReplyWithInstructionSplitsTargetFromWhatToSay() {
        XCTAssertEqual(
            ChatIntentParser.parse("Reply to Sara saying Thursday works", hasPendingDraft: false),
            .draft(DraftRequest(instruction: "thursday works", hints: ["sara"], ordinal: nil, isNewEmail: false))
        )
    }

    func testTellSomebodyThatSomethingIsAReply() {
        XCTAssertEqual(
            ChatIntentParser.parse("Tell Sara that the meeting moved to Friday", hasPendingDraft: false),
            .draft(DraftRequest(
                instruction: "the meeting moved to friday", hints: ["sara"], ordinal: nil, isNewEmail: false
            ))
        )
    }

    func testWriteAnEmailIsANewEmailAndPolitenessIsIgnored() {
        XCTAssertEqual(
            ChatIntentParser.parse("Can you write an email to Tom about the invoice", hasPendingDraft: false),
            .draft(DraftRequest(instruction: nil, hints: ["tom", "invoice"], ordinal: nil, isNewEmail: true))
        )
    }

    func testSendMeAnEmailForSomethingIsANewEmail() {
        // The phrasing that slipped through to the model and came back as
        // prose with no Send button.
        XCTAssertEqual(
            ChatIntentParser.parse("Send me an email for appstore connect", hasPendingDraft: false),
            .draft(DraftRequest(instruction: nil, hints: ["appstore", "connect"], ordinal: nil, isNewEmail: true))
        )
    }

    func testAnAnswerToWhichOneIsReadAsASelection() {
        XCTAssertEqual(ChatIntentParser.selection("Drobe").hints, ["drobe"])
        XCTAssertEqual(ChatIntentParser.selection("the second one").ordinal, 2)
        XCTAssertTrue(ChatIntentParser.selection("the latest").hints.isEmpty)
        XCTAssertEqual(ChatIntentParser.selection("the latest").ordinal, -1)
    }

    func testOrdinalsReferToWhatWasOffered() {
        XCTAssertEqual(
            ChatIntentParser.parse("reply to the first one", hasPendingDraft: false),
            .draft(DraftRequest(instruction: nil, hints: [], ordinal: 1, isNewEmail: false))
        )
    }

    // MARK: - Questions stay questions

    func testAQuestionAboutReplyingIsNotARequestToReply() {
        XCTAssertEqual(
            ChatIntentParser.parse("What should I reply to Sara?", hasPendingDraft: false),
            .question
        )
    }

    func testAnOrdinaryQuestionIsAQuestion() {
        XCTAssertEqual(
            ChatIntentParser.parse("Any deadlines this week?", hasPendingDraft: false),
            .question
        )
    }
}
