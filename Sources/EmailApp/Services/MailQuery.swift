import Foundation

/// What to look for, said in a way every provider can answer.
///
/// This is the type that decides whether the backend protocol survives
/// contact with a second provider. Everything else in the protocol is a verb
/// -- fetch, send, delete -- and verbs translate. A *query* does not: Gmail
/// takes a search string of its own invention, Graph takes OData `$filter`,
/// and IMAP takes a `SEARCH` command with a different grammar again. A
/// protocol that passes `String` around has not abstracted anything, it has
/// just moved Gmail's syntax behind a nicer name.
///
/// So the app says what it means and each backend renders it.
indirect enum MailQuery: Sendable, Equatable {
    /// One of the six folders the app knows about.
    case folder(Mailbox)
    /// The import window, and the reason `newer_than:3m` stopped being a
    /// constant.
    case newerThan(months: Int)
    /// Words, matched wherever the provider matches words.
    case freeText(String)
    case from(String)
    case and([MailQuery])

    /// A query in the provider's own syntax, which only some providers have.
    ///
    /// Not a shortcut -- it is here because of something real. The model
    /// writes Gmail search strings today: the prompt in the `ai` function
    /// literally says *"You turn a description of an email into a Gmail
    /// search query"*, and it is good at it. `from:`, `has:attachment`,
    /// `newer_than:` and the rest are more expressive than anything this
    /// enum will ever carry, and throwing that away to satisfy a protocol
    /// would make search worse for the provider almost everybody uses.
    ///
    /// So it is allowed, and gated: a backend that does not understand it
    /// says so through `acceptsProviderQuerySyntax`, and `rendered(for:)`
    /// falls back to treating it as plain words rather than sending
    /// nonsense. Teaching the model to emit structured criteria is the
    /// better answer and it is a separate job.
    case providerRaw(String)

    /// Everything, unfiltered.
    static let everything = MailQuery.and([])

    // MARK: - Reading

    /// Whether anything here needs syntax the backend may not have.
    var usesProviderSyntax: Bool {
        switch self {
        case .providerRaw: true
        case .and(let parts): parts.contains(where: \.usesProviderSyntax)
        default: false
        }
    }

    /// The same query with provider syntax reduced to plain words, for a
    /// backend that cannot read it. Words are a poorer search than
    /// `from:sara has:attachment`, and a poorer search is better than an
    /// error nobody can act on.
    var withoutProviderSyntax: MailQuery {
        switch self {
        case .providerRaw(let text):
            .freeText(Self.plainWords(in: text))
        case .and(let parts):
            .and(parts.map(\.withoutProviderSyntax))
        default:
            self
        }
    }

    /// Strips `key:value` operators, leaving what a person actually typed.
    ///
    /// `from:sara@example.com invoice march` becomes `invoice march`. The
    /// values are dropped rather than kept because an address matched as a
    /// word finds every message quoting it, which is not what was asked.
    private static func plainWords(in text: String) -> String {
        text
            .split(separator: " ")
            .filter { !$0.contains(":") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
