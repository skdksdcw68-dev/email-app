import Foundation
import Observation

/// Owns the onboarding flow, the Maily account, and the AI preferences the
/// questions collect. Persists across launches so onboarding is answered once.
@Observable
@MainActor
final class UserStore {
    /// Where the user is in the first-run flow. `finished` means the app proper.
    enum Phase: Equatable {
        case splash
        case welcome
        case question(Int)
        case createAccount
        case signIn
        case connectInbox
        case finished
    }

    private(set) var phase: Phase
    private(set) var account: AppAccount?
    /// Answers keyed by question id. A single-select question holds one value.
    private(set) var answers: [String: Set<String>]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, startAt phase: Phase? = nil) {
        self.defaults = defaults
        self.answers = Self.loadAnswers(from: defaults)
        self.account = Self.loadAccount(from: defaults)

        // The splash shows on every launch, not only the first, so it is always
        // the starting phase. `advanceFromSplash` decides where to go next.
        self.phase = phase ?? .splash
    }

    // MARK: - Questions

    var questions: [OnboardingQuestion] { OnboardingQuestion.all }

    func selections(for question: OnboardingQuestion) -> Set<String> {
        answers[question.id] ?? []
    }

    func isSelected(_ option: OnboardingQuestion.Option, in question: OnboardingQuestion) -> Bool {
        selections(for: question).contains(option.id)
    }

    /// Toggling honours the question's selection mode and any exclusive option:
    /// choosing "Nothing, I trust my AI" clears the rest, and choosing anything
    /// else clears it.
    func toggle(_ option: OnboardingQuestion.Option, in question: OnboardingQuestion) {
        var current = selections(for: question)

        switch question.selection {
        case .single:
            current = current.contains(option.id) ? [] : [option.id]

        case .multiple:
            if current.contains(option.id) {
                current.remove(option.id)
            } else if option.isExclusive {
                current = [option.id]
            } else {
                let exclusive = question.options.filter(\.isExclusive).map(\.id)
                current.subtract(exclusive)
                current.insert(option.id)
            }
        }

        answers[question.id] = current
        persistAnswers()
    }

    /// Every question requires at least one answer -- the whole point is to give
    /// the AI something to work with.
    func canContinue(from question: OnboardingQuestion) -> Bool {
        !selections(for: question).isEmpty
    }

    /// The `tone` answer, phrased as an instruction the drafting model can act
    /// on. This is where that onboarding question finally earns its place.
    var tonePreference: String {
        switch selections(for: .tone).first {
        case "professional": "formal and professional"
        case "warm": "warm and friendly"
        case "direct": "short and direct, no filler"
        case "thorough": "detailed and thorough"
        case "casual": "casual and relaxed"
        default: "match how I already write"
        }
    }

    // MARK: - Flow

    /// A returning user still sees the splash -- they just land in the app
    /// rather than in onboarding when it finishes.
    func advanceFromSplash() {
        guard phase == .splash else { return }
        phase = defaults.bool(forKey: Key.completed) ? .finished : .welcome
    }

    func startOnboarding() {
        phase = questions.isEmpty ? .createAccount : .question(0)
    }

    func goToSignIn() {
        phase = .signIn
    }

    func next() {
        switch phase {
        case .question(let index):
            phase = index + 1 < questions.count ? .question(index + 1) : .createAccount
        case .createAccount, .signIn:
            phase = .connectInbox
        case .connectInbox:
            finish()
        case .splash, .welcome, .finished:
            break
        }
    }

    func back() {
        switch phase {
        case .question(let index):
            phase = index == 0 ? .welcome : .question(index - 1)
        case .createAccount:
            phase = questions.isEmpty ? .welcome : .question(questions.count - 1)
        case .signIn:
            phase = .welcome
        case .splash, .welcome, .connectInbox, .finished:
            break
        }
    }

    var canGoBack: Bool {
        switch phase {
        case .question, .createAccount, .signIn: true
        default: false
        }
    }

    /// 0...1 across the question run, for the progress bar.
    var questionProgress: Double? {
        guard case .question(let index) = phase, !questions.isEmpty else { return nil }
        return Double(index + 1) / Double(questions.count)
    }

    // MARK: - Account

    /// Records a completed sign-in and moves the flow on.
    ///
    /// Deliberately takes plain values rather than a Supabase `User`, so the
    /// store stays free of the auth SDK and remains testable without a network.
    /// The view does the mapping.
    ///
    /// A nil email or name never overwrites something already stored: Apple
    /// volunteers both **only on the first authorization**, and every later
    /// sign-in carries the identifier alone.
    func completeSignIn(
        userID: String,
        email: String?,
        displayName: String?,
        provider: AppAccount.Provider
    ) {
        account = AppAccount(
            email: email ?? account?.email ?? "Hidden by provider",
            displayName: displayName ?? account?.displayName ?? "You",
            provider: provider,
            createdAt: account?.createdAt ?? .now,
            externalID: userID
        )
        persistAccount()
        next()
    }

    /// Convenience for Apple, which hands back `PersonNameComponents`.
    func signInWithApple(userID: String, email: String?, fullName: PersonNameComponents?) {
        let formatted = fullName
            .map { PersonNameComponentsFormatter().string(from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        completeSignIn(userID: userID, email: email, displayName: formatted, provider: .apple)
    }

    func signOut() {
        account = nil
        answers = [:]
        defaults.removeObject(forKey: Key.account)
        defaults.removeObject(forKey: Key.answers)
        defaults.set(false, forKey: Key.completed)
        phase = .welcome
    }

    func finish() {
        defaults.set(true, forKey: Key.completed)
        phase = .finished
    }

    // MARK: - Persistence

    private enum Key {
        static let answers = "onboarding.answers"
        static let account = "onboarding.account"
        static let completed = "onboarding.completed"
    }

    private func persistAnswers() {
        guard let data = try? JSONEncoder().encode(answers) else { return }
        defaults.set(data, forKey: Key.answers)
    }

    private func persistAccount() {
        guard let account, let data = try? JSONEncoder().encode(account) else { return }
        defaults.set(data, forKey: Key.account)
    }

    private static func loadAnswers(from defaults: UserDefaults) -> [String: Set<String>] {
        guard let data = defaults.data(forKey: Key.answers),
              let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func loadAccount(from defaults: UserDefaults) -> AppAccount? {
        guard let data = defaults.data(forKey: Key.account) else { return nil }
        return try? JSONDecoder().decode(AppAccount.self, from: data)
    }
}

extension UserDefaults {
    /// A throwaway suite so previews and tests never read or write the real
    /// onboarding state.
    static let previews = UserDefaults(suiteName: "maily.previews") ?? .standard
}
