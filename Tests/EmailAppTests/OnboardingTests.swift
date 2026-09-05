import XCTest
@testable import EmailApp

@MainActor
final class OnboardingTests: XCTestCase {

    /// A fresh, isolated defaults suite per test so nothing leaks between them
    /// or into the real app state.
    private func makeStore(startAt phase: UserStore.Phase = .splash) -> UserStore {
        let suite = "maily.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return UserStore(defaults: defaults, startAt: phase)
    }

    // MARK: - The shape of the question set

    func testQuestionCountIsDivisibleByTwo() {
        XCTAssertEqual(OnboardingQuestion.all.count % 2, 0,
                       "The onboarding question count must be even; it is \(OnboardingQuestion.all.count)")
    }

    func testThereAreEightQuestions() {
        XCTAssertEqual(OnboardingQuestion.all.count, 8)
    }

    func testQuestionIdsAreUnique() {
        let ids = OnboardingQuestion.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testOptionIdsAreUniqueWithinEachQuestion() {
        for question in OnboardingQuestion.all {
            let ids = question.options.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate option id in '\(question.id)'")
        }
    }

    func testEveryQuestionOffersOptions() {
        for question in OnboardingQuestion.all {
            XCTAssertFalse(question.options.isEmpty, "'\(question.id)' has no options")
        }
    }

    func testOnlyMultiSelectQuestionsHaveExclusiveOptions() {
        for question in OnboardingQuestion.all where question.selection == .single {
            XCTAssertTrue(question.options.allSatisfy { !$0.isExclusive },
                          "'\(question.id)' is single-select, so an exclusive option is meaningless")
        }
    }

    // MARK: - Answering

    func testSingleSelectKeepsOnlyOneAnswer() {
        let store = makeStore()
        let q = OnboardingQuestion.role

        store.toggle(q.options[0], in: q)
        store.toggle(q.options[1], in: q)

        XCTAssertEqual(store.selections(for: q), [q.options[1].id])
    }

    func testSingleSelectTogglesOff() {
        let store = makeStore()
        let q = OnboardingQuestion.role

        store.toggle(q.options[0], in: q)
        store.toggle(q.options[0], in: q)

        XCTAssertTrue(store.selections(for: q).isEmpty)
    }

    func testMultiSelectAccumulates() {
        let store = makeStore()
        let q = OnboardingQuestion.priorities

        store.toggle(q.options[0], in: q)
        store.toggle(q.options[1], in: q)

        XCTAssertEqual(store.selections(for: q), [q.options[0].id, q.options[1].id])
    }

    func testExclusiveOptionClearsTheRest() {
        let store = makeStore()
        let q = OnboardingQuestion.approvals
        let exclusive = q.options.first(where: \.isExclusive)!

        store.toggle(q.options[0], in: q)
        store.toggle(q.options[1], in: q)
        store.toggle(exclusive, in: q)

        XCTAssertEqual(store.selections(for: q), [exclusive.id])
    }

    func testPickingAnythingElseClearsTheExclusiveOption() {
        let store = makeStore()
        let q = OnboardingQuestion.approvals
        let exclusive = q.options.first(where: \.isExclusive)!

        store.toggle(exclusive, in: q)
        store.toggle(q.options[0], in: q)

        XCTAssertEqual(store.selections(for: q), [q.options[0].id])
    }

    func testCannotContinueUntilSomethingIsSelected() {
        let store = makeStore()
        let q = OnboardingQuestion.role

        XCTAssertFalse(store.canContinue(from: q))
        store.toggle(q.options[0], in: q)
        XCTAssertTrue(store.canContinue(from: q))
    }

    // MARK: - Flow

    func testSplashLeadsToWelcomeForANewUser() {
        let store = makeStore(startAt: .splash)
        store.advanceFromSplash()
        XCTAssertEqual(store.phase, .welcome)
    }

    func testEveryLaunchStartsOnTheSplash() {
        let suite = "maily.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = UserStore(defaults: defaults, startAt: .connectInbox)
        first.next()
        XCTAssertEqual(first.phase, .finished)

        // A returning user still gets the brand moment on a cold launch.
        let relaunched = UserStore(defaults: defaults)
        XCTAssertEqual(relaunched.phase, .splash)
    }

    func testGetStartedEntersTheQuestions() {
        let store = makeStore(startAt: .welcome)
        store.startOnboarding()
        XCTAssertEqual(store.phase, .question(0))
    }

    func testSignInSkipsTheQuestions() {
        let store = makeStore(startAt: .welcome)
        store.goToSignIn()
        XCTAssertEqual(store.phase, .signIn)

        store.next()
        XCTAssertEqual(store.phase, .connectInbox)
    }

    func testQuestionsRunThroughToAccountCreation() {
        let store = makeStore(startAt: .question(0))
        for _ in OnboardingQuestion.all { store.next() }
        XCTAssertEqual(store.phase, .createAccount)
    }

    func testBackFromFirstQuestionReturnsToWelcome() {
        let store = makeStore(startAt: .question(0))
        store.back()
        XCTAssertEqual(store.phase, .welcome)
    }

    func testConnectingInboxFinishesOnboarding() {
        let store = makeStore(startAt: .connectInbox)
        store.next()
        XCTAssertEqual(store.phase, .finished)
    }

    func testProgressAdvancesAcrossTheQuestions() {
        let first = makeStore(startAt: .question(0))
        let last = makeStore(startAt: .question(OnboardingQuestion.all.count - 1))

        XCTAssertEqual(first.questionProgress ?? -1, 1.0 / Double(OnboardingQuestion.all.count), accuracy: 0.0001)
        XCTAssertEqual(last.questionProgress ?? -1, 1.0, accuracy: 0.0001)
    }

    func testProgressIsNilOutsideTheQuestions() {
        XCTAssertNil(makeStore(startAt: .welcome).questionProgress)
        XCTAssertNil(makeStore(startAt: .finished).questionProgress)
    }

    // MARK: - Account and persistence

    func testCompletingSignInStoresTheAccountWithoutAdvancing() {
        // 🔴 It used to advance to .connectInbox on its own, and that was the
        // hole: from .signIn it did the same thing, so anybody who tapped
        // "Sign in" having never registered went straight past every question
        // into the app. Where somebody goes next depends on what the account
        // already holds, which only the server knows.
        let store = makeStore(startAt: .createAccount)
        store.completeSignIn(userID: "u1", email: "a@b.com", displayName: "Abel", provider: .google)

        XCTAssertNotNil(store.account)
        XCTAssertEqual(store.account?.provider, .google)
        XCTAssertEqual(store.account?.externalID, "u1")
        XCTAssertEqual(store.phase, .createAccount)
    }

    func testAnAccountWithNoAnswersHasNotOnboarded() {
        // The property the routing turns on. A stranger who signs in has
        // nothing stored against them and must answer the questions.
        let store = makeStore(startAt: .signIn)
        XCTAssertFalse(store.hasAnsweredQuestions)
    }

    func testAnyAnswerCountsAsHavingOnboarded() {
        // Any, not all: requiring the full set would trap somebody who
        // abandoned onboarding halfway on an earlier install in a loop they
        // could not finish differently.
        let store = makeStore(startAt: .question(0))
        let question = OnboardingQuestion.role
        store.toggle(question.options[0], in: question)

        XCTAssertTrue(store.hasAnsweredQuestions)
    }

    func testAnswersSurviveARelaunch() {
        let suite = "maily.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let q = OnboardingQuestion.role

        let first = UserStore(defaults: defaults, startAt: .question(0))
        first.toggle(q.options[2], in: q)

        let relaunched = UserStore(defaults: defaults, startAt: .question(0))
        XCTAssertEqual(relaunched.selections(for: q), [q.options[2].id])
    }

    func testAReturningUserLandsInTheAppAfterTheSplash() {
        let suite = "maily.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = UserStore(defaults: defaults, startAt: .connectInbox)
        first.next()
        XCTAssertEqual(first.phase, .finished)

        // Cold launch: splash first, then straight into the app -- never back
        // through onboarding.
        let relaunched = UserStore(defaults: defaults)
        relaunched.advanceFromSplash()
        XCTAssertEqual(relaunched.phase, .finished)
    }

    // MARK: - Sign in with Apple

    func testAppleSignInStoresTheIdentifierAndMovesOn() {
        let store = makeStore(startAt: .createAccount)
        var name = PersonNameComponents()
        name.givenName = "Abel"
        name.familyName = "Amare"

        store.signInWithApple(userID: "001234.abc", email: "abel@example.com", fullName: name)

        XCTAssertEqual(store.account?.externalID, "001234.abc")
        XCTAssertEqual(store.account?.email, "abel@example.com")
        XCTAssertEqual(store.account?.provider, .apple)
        // Storing the account no longer moves anybody. See
        // testCompletingSignInStoresTheAccountWithoutAdvancing.
        XCTAssertEqual(store.phase, .createAccount)
    }

    /// Apple sends name and email only on the first authorization; every later
    /// sign-in carries the identifier alone.
    func testLaterAppleSignInKeepsTheStoredNameAndEmail() {
        let store = makeStore(startAt: .createAccount)
        var name = PersonNameComponents()
        name.givenName = "Abel"

        store.signInWithApple(userID: "001234.abc", email: "abel@example.com", fullName: name)
        store.signInWithApple(userID: "001234.abc", email: nil, fullName: nil)

        XCTAssertEqual(store.account?.email, "abel@example.com")
        XCTAssertEqual(store.account?.displayName, "Abel")
    }

    func testAppleSignInWithNothingStillProducesAnAccount() {
        let store = makeStore(startAt: .createAccount)
        store.signInWithApple(userID: "001234.xyz", email: nil, fullName: nil)

        XCTAssertEqual(store.account?.email, "Hidden by provider")
        XCTAssertEqual(store.account?.displayName, "You")
    }

    func testSignOutClearsEverythingAndReturnsToWelcome() {
        let store = makeStore(startAt: .createAccount)
        store.completeSignIn(userID: "u1", email: "a@b.com", displayName: "Abel", provider: .google)
        store.finish()

        store.signOut()

        XCTAssertNil(store.account)
        XCTAssertTrue(store.answers.isEmpty)
        XCTAssertEqual(store.phase, .welcome)
    }
}
