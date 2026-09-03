import Testing
import Foundation
@testable import EmailApp

/// Each of these is a conversation that used to go wrong.
struct ChatStateTests {

    @Test func afreshConversationSaysNothing() {
        // A first question should cost nothing extra. Nil, not an empty
        // paragraph the model has to read past.
        #expect(ChatState.fresh.briefing() == nil)
    }

    @Test func aFailedSearchIsRememberedSoItIsNotRepeated() {
        var state = ChatState.fresh
        state.searched("upwork welcome", found: 0)
        state.searched("upwork registration", found: 0)

        let briefing = state.briefing() ?? ""
        #expect(briefing.contains("upwork welcome"))
        #expect(briefing.contains("upwork registration"))
        #expect(briefing.contains("Do not search for those words again"))
    }

    @Test func aSearchThatWorkedIsToldApartFromOneThatDidNot() {
        var state = ChatState.fresh
        state.searched("invoice", found: 4)
        state.searched("receipt", found: 0)

        let briefing = state.briefing() ?? ""
        #expect(briefing.contains("found something: \"invoice\""))
        #expect(briefing.contains("found nothing: \"receipt\""))
    }

    @Test func theSameQueryIsRecordedOnce() {
        var state = ChatState.fresh
        state.searched("invoice", found: 0)
        state.searched("Invoice", found: 0)

        #expect(state.tried.count == 1)
    }

    @Test func findingSomethingLaterUpgradesTheAttempt() {
        // A query that missed on one hop and hit on the next is not a query
        // to warn the model off.
        var state = ChatState.fresh
        state.searched("invoice", found: 0)
        state.searched("invoice", found: 3)

        #expect(state.tried.first?.found == 3)
        #expect(!(state.briefing() ?? "").contains("found nothing"))
    }

    @Test func onlySoManySearchesAreKept() {
        var state = ChatState.fresh
        for index in 0..<20 { state.searched("query \(index)", found: 0) }

        #expect(state.tried.count <= 8)
        // The recent ones, which are the ones about to be tried again.
        #expect(state.tried.last?.query == "query 19")
    }

    @Test func blankQueriesAreNotRecorded() {
        var state = ChatState.fresh
        state.searched("   ", found: 0)
        #expect(state.tried.isEmpty)
    }

    // MARK: - Who it is about

    @Test func aQuestionThatNamesNobodyKeepsWhoCameBefore() {
        var state = ChatState.fresh
        state.asking("what's happening with Sara?", about: ["Sara Chen"])
        state.answered(found: 0, searched: false)

        state.asking("and what did she say about the invoice?", about: [])

        #expect(state.people == ["Sara Chen"])
        #expect((state.briefing() ?? "").contains("Sara Chen"))
    }

    @Test func aQuestionThatNamesSomebodyElseMovesOn() {
        var state = ChatState.fresh
        state.asking("what's happening with Sara?", about: ["Sara Chen"])
        state.asking("what about David?", about: ["David Okoro"])

        #expect(state.people == ["David Okoro"])
    }

    // MARK: - What is still open

    @Test func aSearchThatFoundNothingLeavesTheQuestionOpen() {
        var state = ChatState.fresh
        state.asking("when did I register on Upwork?", about: [])
        state.searched("upwork welcome", found: 0)
        state.answered(found: 0, searched: true)

        #expect(state.unresolved == "when did I register on Upwork?")
        #expect((state.briefing() ?? "").contains("Still unanswered"))
    }

    @Test func findingSomethingClosesIt() {
        var state = ChatState.fresh
        state.asking("when did I register on Upwork?", about: [])
        state.answered(found: 2, searched: true)

        #expect(state.unresolved == nil)
    }

    @Test func aQuestionAnsweredWithoutLookingIsNotLeftOpen() {
        // Answered from the mail already to hand. Nothing was searched for,
        // so nothing is outstanding.
        var state = ChatState.fresh
        state.asking("what needs my attention?", about: [])
        state.answered(found: 0, searched: false)

        #expect(state.unresolved == nil)
    }

    @Test func anAsideDoesNotBecomeTheSubject() {
        var state = ChatState.fresh
        state.asking("when did I register on Upwork?", about: [])
        state.answered(found: 0, searched: true)
        #expect(state.unresolved != nil)

        // "What can you do" is not about mail, and should not leave the
        // conversation thinking it was.
        state.asking("what can you do?", about: [])
        state.setAside()

        #expect(state.unresolved == nil)
    }

    @Test func thefirstOpenQuestionSurvivesAFollowUp() {
        // A follow-up asked while something is still open is usually about
        // that same thing. Overwriting would lose what was being looked for.
        var state = ChatState.fresh
        state.asking("when did I register on Upwork?", about: [])
        state.answered(found: 0, searched: true)
        state.asking("try again", about: [])

        #expect(state.unresolved == "when did I register on Upwork?")
    }
}
