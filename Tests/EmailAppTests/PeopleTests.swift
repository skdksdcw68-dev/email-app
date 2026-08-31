import XCTest
@testable import EmailApp

final class PeopleTests: XCTestCase {

    private let me = "abel@maily.com"

    override func setUp() {
        super.setUp()
        PersonPreferences.clearAll()
    }

    override func tearDown() {
        PersonPreferences.clearAll()
        super.tearDown()
    }

    private func message(
        from: String,
        to: String,
        thread: String,
        daysAgo: Int = 1,
        mailbox: Mailbox = .inbox,
        tags: Set<AITag> = []
    ) -> Message {
        var message = Message(
            sender: Contact(name: from, address: from),
            recipients: [Contact(name: to, address: to)],
            subject: "Subject",
            body: "Body",
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            mailbox: mailbox,
            tags: tags
        )
        message.threadID = thread
        return message
    }

    // MARK: - Category inference

    func testSameDomainIsAColleague() {
        XCTAssertEqual(
            PersonCategory.inferred(for: "sara@maily.com", myDomain: "maily.com"),
            .colleague
        )
    }

    func testConsumerDomainIsPersonal() {
        XCTAssertEqual(
            PersonCategory.inferred(for: "mum@gmail.com", myDomain: "maily.com"),
            .personal
        )
    }

    func testAPersonAtAnotherCompanyIsExternal() {
        XCTAssertEqual(
            PersonCategory.inferred(for: "sara@stripe.com", myDomain: "maily.com"),
            .external
        )
    }

    func testARoleAddressAtAnotherCompanyIsAService() {
        // billing@ is a mailbox, not a person, even on a real company domain.
        // The first version of the test above used billing@stripe.com and
        // expected External -- the test was wrong, not the rule.
        XCTAssertEqual(
            PersonCategory.inferred(for: "billing@stripe.com", myDomain: "maily.com"),
            .service
        )
    }

    func testNoReplyIsAService() {
        XCTAssertEqual(
            PersonCategory.inferred(for: "noreply@github.com", myDomain: "maily.com"),
            .service
        )
    }

    func testASharedConsumerDomainDoesNotMakeEveryoneAColleague() {
        // Both on gmail.com is not a workplace. Without this guard, every
        // gmail user would be a "colleague" of every other one.
        XCTAssertEqual(
            PersonCategory.inferred(for: "friend@gmail.com", myDomain: "gmail.com"),
            .personal
        )
    }

    func testBulkSendersAreServices() {
        XCTAssertEqual(
            PersonCategory.inferred(for: "hi@brand.com", myDomain: "maily.com", isBulk: true),
            .service
        )
    }

    func testServicesAreNotPeople() {
        XCTAssertFalse(PersonCategory.service.isPerson)
        XCTAssertTrue(PersonCategory.colleague.isPerson)
    }

    // MARK: - Assembling people

    func testBothDirectionsCountTowardsOnePerson() {
        let people = [
            message(from: "sara@x.com", to: me, thread: "t1"),
            message(from: me, to: "sara@x.com", thread: "t1", mailbox: .sent),
        ].people(myAddress: me)

        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].messageCount, 2)
        XCTAssertEqual(people[0].conversationCount, 1)
    }

    func testTheUserIsNotListedAsAPerson() {
        let people = [message(from: me, to: "sara@x.com", thread: "t1", mailbox: .sent)]
            .people(myAddress: me)
        XCTAssertFalse(people.contains { $0.id == me })
    }

    func testWhoStartedEachConversation() {
        let people = [
            message(from: "sara@x.com", to: me, thread: "t1", daysAgo: 10),
            message(from: me, to: "sara@x.com", thread: "t1", daysAgo: 9, mailbox: .sent),
            message(from: me, to: "sara@x.com", thread: "t2", daysAgo: 5, mailbox: .sent),
        ].people(myAddress: me)

        XCTAssertEqual(people[0].theyStarted, 1)
        XCTAssertEqual(people[0].youStarted, 1)
    }

    func testInitiatorStaysQuietWithoutEnoughHistory() {
        // Two conversations is not a pattern worth asserting.
        let people = [
            message(from: "sara@x.com", to: me, thread: "t1")
        ].people(myAddress: me)
        XCTAssertNil(people[0].initiator)
    }

    func testInitiatorIsReportedWhenLopsided() {
        let messages = (1...4).map {
            message(from: "sara@x.com", to: me, thread: "t\($0)", daysAgo: $0)
        }
        XCTAssertEqual(messages.people(myAddress: me)[0].initiator, "They usually reach out first")
    }

    func testOrganizationComesFromACompanyDomain() {
        let people = [message(from: "billing@stripe.com", to: me, thread: "t1")]
            .people(myAddress: me)
        XCTAssertEqual(people[0].organization, "Stripe")
    }

    func testNoOrganizationForAConsumerDomain() {
        let people = [message(from: "mum@gmail.com", to: me, thread: "t1")]
            .people(myAddress: me)
        XCTAssertNil(people[0].organization)
    }

    // MARK: - Preferences

    func testImportantAndMutedAreMutuallyExclusive() {
        PersonPreferences.setMuted(true, for: "sara@x.com")
        PersonPreferences.setImportant(true, for: "sara@x.com")

        XCTAssertTrue(PersonPreferences.isImportant("sara@x.com"))
        XCTAssertFalse(PersonPreferences.isMuted("sara@x.com"))
    }

    func testPreferencesAreCaseInsensitive() {
        PersonPreferences.setImportant(true, for: "Sara@X.com")
        XCTAssertTrue(PersonPreferences.isImportant("sara@x.com"))
    }

    func testImportantLiftsPriorityButDoesNotDecideIt() {
        // Weight, not a verdict: the adjustment must not be big enough on its
        // own to push an unremarkable message into the top tier.
        XCTAssertEqual(PersonPreferences.scoreAdjustment(for: "nobody@x.com"), 0)

        PersonPreferences.setImportant(true, for: "sara@x.com")
        let lift = PersonPreferences.scoreAdjustment(for: "sara@x.com")
        XCTAssertGreaterThan(lift, 0)
        XCTAssertLessThan(lift, 55, "An importance mark alone should not reach the urgent threshold")
    }

    func testMutingPushesPriorityDown() {
        PersonPreferences.setMuted(true, for: "chatty@x.com")
        XCTAssertLessThan(PersonPreferences.scoreAdjustment(for: "chatty@x.com"), 0)
    }

    func testAUserCategoryOverridesTheInferredOne() {
        PersonPreferences.setCategory(.personal, for: "billing@stripe.com")
        let people = [message(from: "billing@stripe.com", to: me, thread: "t1")]
            .people(myAddress: me)
        XCTAssertEqual(people[0].category, .personal)
    }

    // MARK: - Ordering

    func testImportantPeopleSortFirst() {
        PersonPreferences.setImportant(true, for: "quiet@x.com")
        let people = [
            message(from: "loud@x.com", to: me, thread: "t1", daysAgo: 0, tags: [.needsReply]),
            message(from: "quiet@x.com", to: me, thread: "t2", daysAgo: 30),
        ].people(myAddress: me)

        XCTAssertEqual(people.first?.id, "quiet@x.com")
    }

    func testUnansweredSortsAboveMerelyRecent() {
        let people = [
            message(from: "recent@x.com", to: me, thread: "t1", daysAgo: 0),
            message(from: "waiting@x.com", to: me, thread: "t2", daysAgo: 5, tags: [.needsReply]),
        ].people(myAddress: me)

        XCTAssertEqual(people.first?.id, "waiting@x.com")
    }
}
