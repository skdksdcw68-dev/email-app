import XCTest
@testable import EmailApp

/// What is left after the canned answers were removed: only the cases where
/// misreading a sentence performs an action, or fails to.
final class ChatIntentTests: XCTestCase {

    // MARK: - Small talk is not an action

    func testGreetingsAreQuestionsNow() {
        // No canned reply, no local table. Everything that is only words
        // goes to the model, which is better at words.
        for phrase in ["hi", "Hey Maily!", "thanks a lot", "ok", "what can you do"] {
            XCTAssertEqual(ChatIntentParser.parse(phrase, hasPendingDraft: false), .question, phrase)
        }
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

    // MARK: - Marking read

    func testMarkingANamedPileAsRead() {
        XCTAssertEqual(
            ChatIntentParser.parse("Mark the newsletters as read", hasPendingDraft: false),
            .markRead(MarkReadRequest(tag: .newsletter, isEverything: false))
        )
    }

    func testMarkingEverythingAsRead() {
        XCTAssertEqual(
            ChatIntentParser.parse("mark everything as read", hasPendingDraft: false),
            .markRead(MarkReadRequest(tag: nil, isEverything: true))
        )
    }

    func testMarkingWhatWasJustListed() {
        let intent = ChatIntentParser.parse("mark them as read", hasPendingDraft: false)
        XCTAssertEqual(intent, .markRead(MarkReadRequest(tag: nil, isEverything: false)))
        if case .markRead(let request) = intent {
            XCTAssertTrue(request.isImplicit)
        }
    }

    /// "Mark the reply from Sara as read" must not trip the reply verb and
    /// start writing an email nobody asked for.
    func testMarkingReadBeatsTheReplyVerb() {
        let intent = ChatIntentParser.parse("mark the reply from Sara as read", hasPendingDraft: false)
        guard case .markRead = intent else {
            return XCTFail("Expected a mark-read request, got \(intent)")
        }
    }

    func testMarkingUnreadIsNotSilentlyTreatedAsRead() {
        // The opposite request. Doing the wrong one of these is worse than
        // doing neither.
        XCTAssertNotEqual(
            ChatIntentParser.parse("mark it as unread", hasPendingDraft: false),
            .markRead(MarkReadRequest(tag: nil, isEverything: false))
        )
    }

    func testReadingIsNotMarkingRead() {
        // "Read me the newsletters" is a request for their contents.
        XCTAssertEqual(
            ChatIntentParser.parse("read me the newsletters", hasPendingDraft: false),
            .question
        )
    }

    // MARK: - Remembering

    func testRememberStoresWhatFollowsIt() {
        XCTAssertEqual(
            ChatIntentParser.parse("Remember that I sign off as Abel", hasPendingDraft: false),
            .remember("I sign off as Abel")
        )
        XCTAssertEqual(
            ChatIntentParser.parse("keep in mind I hate exclamation marks", hasPendingDraft: false),
            .remember("I hate exclamation marks")
        )
    }

    func testARememberedFactKeepsItsCapitals() {
        // It gets read back to the person in a card and in Settings, so it
        // must not come back lowercased the way a parsed command would.
        guard case .remember(let fact) = ChatIntentParser.parse(
            "remember: Yohannes is my accountant", hasPendingDraft: false
        ) else { return XCTFail("expected a memory") }
        XCTAssertEqual(fact, "Yohannes is my accountant")
    }

    func testAskingWhetherItRemembersIsAQuestion() {
        // "Do you remember what Sara said" must not be stored as a fact
        // about the person.
        XCTAssertEqual(
            ChatIntentParser.parse("Do you remember what Sara said?", hasPendingDraft: false),
            .question
        )
    }

    func testRememberWithNothingAfterItIsAQuestion() {
        XCTAssertEqual(ChatIntentParser.parse("remember", hasPendingDraft: false), .question)
    }

}
