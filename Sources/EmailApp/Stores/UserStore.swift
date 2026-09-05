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
        SettingsSync.notify(.onboarding)
    }

    /// Every question requires at least one answer -- the whole point is to give
    /// the AI something to work with.
    func canContinue(from question: OnboardingQuestion) -> Bool {
        !selections(for: question).isEmpty
    }

    /// Changes the tone answer from Settings, without walking onboarding again.
    /// Writes the same store the questions do, so the two can never disagree.
    /// Renames the account. The only part of the profile the user owns; the
    /// email comes from whoever they signed in with and cannot be edited here.
    func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var updated = account, !trimmed.isEmpty else { return }
        updated.displayName = trimmed
        account = updated
        persistAccount()
        SettingsSync.notify(.onboarding)
    }

    /// What they do, in their own words. Cleared rather than stored empty, so
    /// nothing downstream has to decide whether "" means anything.
    func setOccupation(_ occupation: String) {
        let trimmed = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var updated = account else { return }
        updated.occupation = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        account = updated
        persistAccount()
        SettingsSync.notify(.onboarding)
    }

    /// Sets the tone for the mailbox in front of you.
    ///
    /// ⚠️ Writes the *mailbox* override, not the onboarding answer. Changing
    /// the voice of a work address should not quietly rewrite what somebody
    /// said about themselves at signup -- that answer is the fallback for
    /// every mailbox that has not been given one of its own, so overwriting it
    /// would change every one of them at once.
    ///
    /// The onboarding answer is still editable, in Personalization, where it
    /// is labelled as the answer it is.
    func setTone(_ optionID: String) {
        AppSettings.mailboxTone = optionID
    }

    /// Puts this mailbox back on the signup answer.
    func clearMailboxTone() {
        AppSettings.mailboxTone = nil
    }

    /// The onboarding tone answer itself, edited from Personalization.
    func setSignupTone(_ optionID: String) {
        answers[OnboardingQuestion.tone.id] = [optionID]
        persistAnswers()
        SettingsSync.notify(.onboarding)
    }

    /// The `tone` answer, phrased as an instruction the drafting model can act
    /// on. This is where that onboarding question finally earns its place.
    ///
    /// Read off `WritingTone` rather than switched on here.
    ///
    /// There used to be two copies of this mapping -- one here and one on
    /// `WritingTone`, whose doc comment said "must match what
    /// `UserStore.tonePreference` produces". Two lists that must agree, and
    /// nothing making them. Adding a tone to the picker silently fell through
    /// to the default here, so the screen showed it selected while the model
    /// was told something else entirely.
    /// The tone the *active mailbox* writes in.
    ///
    /// Two layers, and the order is the point. A mailbox that has been given
    /// its own tone uses it; one that has not falls back to the answer given
    /// at signup. So a newly connected address starts in the voice somebody
    /// already chose, rather than in a default nobody picked -- and changing
    /// it there changes only that address.
    var chosenTone: WritingTone {
        if let perMailbox = AppSettings.mailboxTone,
           let tone = WritingTone(rawValue: perMailbox) {
            return tone
        }
        return WritingTone(rawValue: selections(for: .tone).first ?? "") ?? .matchMe
    }

    /// Whether this mailbox has been given a voice of its own, as opposed to
    /// inheriting the signup answer. The Writing screen says which it is.
    var hasMailboxTone: Bool { AppSettings.mailboxTone != nil }

    var tonePreference: String { chosenTone.instruction }

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
        provider: AppAccount.Provider,
        photoURL: URL? = nil
    ) {
        // Same rule as the name and the email: a nil never overwrites
        // something already held. Apple volunteers nothing on a second
        // sign-in, and a picture that disappeared on the second launch would
        // look like the app had lost it.
        let keptID = account?.id ?? UUID()
        account = AppAccount(
            id: keptID,
            email: email ?? account?.email ?? "Hidden by provider",
            displayName: displayName ?? account?.displayName ?? "You",
            provider: provider,
            createdAt: account?.createdAt ?? .now,
            externalID: userID,
            photoURL: photoURL ?? account?.photoURL
        )
        persistAccount()
        if let photo = account?.photoURL {
            AvatarStore.shared.ensure(key: "app-\(keptID.uuidString)", url: photo)
        }
        SettingsSync.notify(.profile)
        // 🔴 Deliberately does not advance any more.
        //
        // It called `next()`, which from `.signIn` goes to `.connectInbox` --
        // so anybody who tapped "Sign in" landed in the app having answered
        // nothing, whether or not they had ever registered. Every question
        // that shapes how Maily behaves was skipped, with no way back to
        // them.
        //
        // Where somebody goes next depends on what the *account* already
        // holds, and only the server knows that. `continueAfterAuth()` asks.
    }

    /// Picks up the provider's picture for an account that already exists.
    ///
    /// 🔴 Without this the change would only reach people who sign in again.
    /// `completeSignIn` runs once, at sign-in, and everybody already using
    /// Maily is long past it -- so the field would stay nil on exactly the
    /// accounts that prompted the work. Signing out to get a profile picture
    /// is not a thing to ask of anybody.
    ///
    /// Cheap enough for every launch: reading the session is local, and the
    /// download below is skipped entirely while the stored copy is fresh.
    func refreshProviderPhoto() async {
        guard var held = account else { return }
        guard let photo = await AuthService.currentProviderPhoto() else {
            // Nothing to take. Any picture already stored stays -- a provider
            // that is briefly unreachable has not deleted anybody's face.
            if let existing = held.photoURL {
                AvatarStore.shared.ensure(key: "app-\(held.id.uuidString)", url: existing)
            }
            return
        }

        if held.photoURL != photo {
            held.photoURL = photo
            account = held
            persistAccount()
        }
        AvatarStore.shared.ensure(key: "app-\(held.id.uuidString)", url: photo)
    }

    /// Where somebody lands once they are signed in.
    ///
    /// One rule rather than a branch on which button they pressed: an account
    /// that has answered the questions goes on to connect a mailbox, one that
    /// has not answers them first. Somebody who just finished the questions
    /// has answers, so this sends them onward exactly as before -- and
    /// somebody who pressed "Sign in" having never registered is sent *to* the
    /// questions rather than past them.
    func continueAfterAuth() async {
        // What this account already has. Without it a genuine returning user
        // on a new phone looks identical to a stranger -- both have an empty
        // local `answers` -- and would be made to answer everything again.
        await SettingsSync.shared.pull()

        phase = hasAnsweredQuestions ? .connectInbox : .question(0)
    }

    /// Whether this account has been through the questions at all.
    ///
    /// Any answer counts. Requiring all of them would trap somebody who
    /// abandoned onboarding halfway on an earlier install in a loop they
    /// could not get out of.
    var hasAnsweredQuestions: Bool {
        answers.values.contains { !$0.isEmpty }
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
        // The signup snapshot goes too. Keeping it would mean the next person
        // to sign in on this phone could reset to a stranger's answers.
        defaults.removeObject(forKey: Key.originalAnswers)
        // 🔴 Cancel, never flush. A debounced push firing after this would
        // send the emptied answers up and wipe the account on every other
        // device. Signing out is not an edit.
        SettingsSync.shared.cancelPending()
        defaults.set(false, forKey: Key.completed)
        phase = .welcome
    }

    func finish() {
        defaults.set(true, forKey: Key.completed)
        // What they answered at signup, kept so Personalization can offer to
        // put it back. There is only ever one `answers` dictionary and editing
        // it later overwrites in place, so without a snapshot taken here the
        // original choices are gone the first time somebody taps a row to see
        // what it does.
        //
        // Written once, at the end of onboarding, and never again -- a reset
        // that restored "whatever it was last week" would not be a reset.
        if let data = try? JSONEncoder().encode(answers) {
            defaults.set(data, forKey: Key.originalAnswers)
        }
        phase = .finished
    }

    // MARK: - The signup baseline

    /// Whether there is anything to go back to. False for anybody who
    /// onboarded before the snapshot existed, and the Reset button hides
    /// rather than offering to restore nothing.
    var hasSignupAnswers: Bool {
        defaults.data(forKey: Key.originalAnswers) != nil
    }

    /// Whether what they have now differs from what they picked at signup.
    var hasChangedSinceSignup: Bool {
        guard let original = signupAnswers else { return false }
        return original != answers
    }

    private var signupAnswers: [String: Set<String>]? {
        guard let data = defaults.data(forKey: Key.originalAnswers) else { return nil }
        return try? JSONDecoder().decode([String: Set<String>].self, from: data)
    }

    /// Puts the signup answers back.
    func resetToSignupAnswers() {
        guard let original = signupAnswers else { return }
        answers = original
        persistAnswers()
        SettingsSync.notify(.onboarding)
    }

    /// Takes the answers another device saved.
    ///
    /// Whole-document rather than merged: these are eight questions with one
    /// current answer each, not a growing set, and "the newest device wins"
    /// is what somebody means by changing an answer.
    func replaceAnswers(_ incoming: [String: Set<String>]) {
        guard !incoming.isEmpty else { return }
        answers = incoming
        persistAnswers()
        SettingsSync.notify(.onboarding)
    }

    // MARK: - Persistence

    private enum Key {
        static let answers = "onboarding.answers"
        static let originalAnswers = "onboarding.answers.original"
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

extension UserStore {
    /// The tone they chose, as the one word a settings row can carry. The
    /// full instruction is what the model reads; this is what a person does.
    var writingToneTitle: String { chosenTone.title }
}
