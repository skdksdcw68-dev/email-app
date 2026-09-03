import Testing
import Foundation
@testable import EmailApp

/// The embedding assets are part of iOS, not of this app, so these check the
/// shape of what comes back rather than asserting particular neighbours --
/// pinning "laptop → macbook" would be a test of Apple's model, and it would
/// break on an OS update that improved it.
///
/// Everything here is on-device. If any of this ever needs a network call,
/// that is a Gmail Limited Use problem, not a performance one.
struct SemanticIndexTests {

    @Test func expandingNothingFindsNothing() {
        #expect(SemanticIndex.expand([]).isEmpty)
    }

    @Test func expansionNeverRepeatsWhatWasTyped() {
        let typed: Set<String> = ["invoice", "payment"]
        let extra = SemanticIndex.expand(typed)
        #expect(extra.isDisjoint(with: typed))
    }

    @Test func expansionSkipsVeryShortWords() {
        // Three letters and under match too much to be worth adding.
        for word in SemanticIndex.expand(["laptop", "meeting"]) {
            #expect(word.count > 3)
        }
    }

    @Test func expansionStaysProportionate() {
        // Two words in should not mean forty out. The cap is what keeps this
        // from quietly matching half the mailbox.
        let extra = SemanticIndex.expand(["laptop", "invoice"])
        #expect(extra.count <= 2 * SemanticIndex.neighboursPerWord)
    }

    /// Skipped rather than failed where the asset is missing. A CI runner
    /// without the English embedding is not a broken app -- the whole point
    /// of `canExpand` is that the app carries on without it.
    @Test(.enabled(if: SemanticIndex.canExpand))
    func aRelatedWordActuallyTurnsUp() {
        let extra = SemanticIndex.expand(["laptop"])
        #expect(!extra.isEmpty, "laptop should have near neighbours")
    }

    // MARK: - Ranking

    private func message(_ subject: String, _ body: String) -> Message {
        var message = Message(
            sender: Contact(name: "Sam", address: "sam@example.com"),
            recipients: [],
            subject: subject,
            body: body,
            date: .now
        )
        message.remoteID = subject
        return message
    }

    @Test func rankingAnEmptyListIsEmpty() {
        #expect(SemanticIndex.similarity(of: [], to: "anything").isEmpty)
    }

    @Test func aBlankQuestionRanksNothing() {
        let candidates = [message("Invoice", "The invoice is attached")]
        #expect(SemanticIndex.similarity(of: candidates, to: "  ").isEmpty)
    }

    /// The simulator ships the word embedding and not the sentence one, so
    /// these three do not run there. On a device they do.
    @Test(.enabled(if: SemanticIndex.canRank))
    func scoresStayInRange() {
        let candidates = [
            message("Invoice for August", "Please find the invoice attached."),
            message("Lunch on Friday", "Are you free at one?"),
        ]
        for (_, score) in SemanticIndex.similarity(of: candidates, to: "where is my bill") {
            #expect(score >= 0)
            #expect(score <= 1)
        }
    }

    @Test(.enabled(if: SemanticIndex.canRank))
    func theCloserMeaningScoresHigher() {
        let bill = message("Invoice for August", "Please find the invoice attached, payment due in 30 days.")
        let lunch = message("Lunch on Friday", "Are you free at one? There is a new place on the corner.")

        let scores = SemanticIndex.similarity(of: [bill, lunch], to: "when do I have to pay that bill")
        guard let billScore = scores[bill.id], let lunchScore = scores[lunch.id] else {
            Issue.record("Both messages should have been scored")
            return
        }
        #expect(billScore > lunchScore)
    }

    @Test(.enabled(if: SemanticIndex.canRank))
    func onlyTheShortlistIsEmbedded() {
        // Embedding is per-message work, and a mailbox is thousands of them.
        // The cap is the whole reason a question stays fast.
        let many = (0..<(SemanticIndex.shortlist + 50)).map {
            message("Subject \($0)", "Some body text about work and meetings.")
        }
        let scores = SemanticIndex.similarity(of: many, to: "meetings this week")
        #expect(scores.count <= SemanticIndex.shortlist)
    }
}
