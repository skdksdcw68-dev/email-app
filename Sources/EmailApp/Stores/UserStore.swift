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
    private(set) var isWorking = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, startAt phase: Phase? = nil) {
        self.defaults = defaults
        self.answers = Self.loadAnswers(from: defaults)
        self.account = Self.loadAccount(from: defaults)

        if let phase {
            self.phase = phase
        } else if defaults.bool(forKey: Key.completed) {
            // A returning user never sees onboarding again.
            self.phase = .finished
        } else {
            self.phase = .splash
        }
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

    // MARK: - Flow

    func advanceFromSplash() {
        guard phase == .splash else { return }
        phase = .welcome
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

    /// Stubbed sign-up. Real Apple/Google/email auth replaces the body; nothing
    /// outside this method needs to change.
    func createAccount(with provider: AppAccount.Provider) async {
        guard !isWorking else { return }
        isWorking = true
        try? await Task.sleep(for: .seconds(0.9))

        account = AppAccount(
            email: "abelamare1633@gmail.com",
            displayName: "Abel Amare",
            provider: provider,
            createdAt: .now
        )
        persistAccount()
        isWorking = false
        next()
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
