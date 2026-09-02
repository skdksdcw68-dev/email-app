import Foundation

/// One thing Maily actually did, while it was doing it.
///
/// The chat used to show a single string that each stage overwrote, so a
/// question answered after three searches looked identical to one answered
/// from memory. You could not see the work, which meant you could not judge
/// the answer.
///
/// The important part of this type is what it will **not** let you build.
/// There is no `init(kind:detail:)`. Every step is derived from the thing it
/// describes -- a step about a search takes the results and counts them
/// itself, a step about reading takes the messages. So "Searching 1,582
/// emails" cannot be written by a code path that looked at twenty, because
/// the number is never something a caller passes in.
///
/// That matters more than it sounds. A progress line nobody can verify is
/// decoration, and decoration that claims work is a lie the app tells every
/// time it runs. Making it structurally impossible is cheaper than
/// remembering not to.
struct TaskStep: Equatable, Codable, Identifiable {

    enum Kind: String, Equatable, Codable {
        case understanding
        case searching
        case reading
        case comparing
        case writing

        var symbol: String {
            switch self {
            case .understanding: "sparkles"
            case .searching:     "magnifyingglass"
            case .reading:       "text.alignleft"
            case .comparing:     "arrow.left.arrow.right"
            case .writing:       "square.and.pencil"
            }
        }
    }

    var id = UUID()
    let kind: Kind
    let detail: String
    var isDone = false

    /// Private on purpose. Everything below derives its own wording.
    private init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    // MARK: - Derived steps

    static func understanding() -> TaskStep {
        TaskStep(kind: .understanding, detail: "Working out what would answer this")
    }

    /// The count comes from the results, never from the caller.
    static func searched(_ query: String, found: [Message]) -> TaskStep {
        let outcome = found.isEmpty
            ? "nothing"
            : (found.count == 1 ? "1 email" : "\(found.count) emails")
        return TaskStep(kind: .searching, detail: "Searched \u{201C}\(query)\u{201D} \u{2014} \(outcome)")
    }

    /// Searching the mail already on the phone, which costs nothing and is
    /// instant. Worth naming separately: it is a different promise from
    /// reaching into the account.
    static func searchedLocally(_ query: String, found: [Message]) -> TaskStep {
        let outcome = found.isEmpty
            ? "nothing here"
            : (found.count == 1 ? "1 email here" : "\(found.count) emails here")
        return TaskStep(kind: .searching, detail: "Checked what you have \u{2014} \(outcome)")
    }

    static func reading(_ messages: [Message]) -> TaskStep {
        let count = messages.count
        return TaskStep(
            kind: .reading,
            detail: count == 1 ? "Reading 1 email" : "Reading \(count) emails"
        )
    }

    static func comparing(_ messages: [Message]) -> TaskStep {
        TaskStep(kind: .comparing, detail: "Comparing \(messages.count) candidates")
    }

    static func writing(to name: String) -> TaskStep {
        TaskStep(kind: .writing, detail: "Writing to \(name)")
    }

    // MARK: - Summarising a finished trail

    /// "4 steps, 2 searches". What the collapsed line says once the answer
    /// has landed, counted from the steps themselves.
    static func summary(of steps: [TaskStep]) -> String {
        guard !steps.isEmpty else { return "" }
        let searches = steps.filter { $0.kind == .searching }.count
        let stepPart = steps.count == 1 ? "1 step" : "\(steps.count) steps"
        guard searches > 0 else { return stepPart }
        let searchPart = searches == 1 ? "1 search" : "\(searches) searches"
        return "\(stepPart) \u{00B7} \(searchPart)"
    }
}
