import Foundation

/// Searching the whole mailbox, not only the part of it this phone happens
/// to hold.
///
/// Typing filters the local copy instantly, which is the right behaviour for
/// the three months already on the device. Pressing search asks Gmail, whose
/// index covers everything back to the beginning of the account, and merges
/// what comes back so the results are openable like any other message.
///
/// Two modes, and the difference is worth being honest about. **Mail** sends
/// the words to Gmail as typed and costs nothing. **AI** spends a model call
/// to turn "that invoice from the landlord last spring" into a real Gmail
/// query with dates and senders in it, and says so before it does.
extension MailStore {

    enum SearchMode: String, CaseIterable, Identifiable {
        case mail
        case ai

        var id: Self { self }

        var title: String {
            switch self {
            case .mail: "Mail"
            case .ai:   "Ask AI"
            }
        }

        var symbol: String {
            switch self {
            case .mail: "magnifyingglass"
            case .ai:   "sparkles"
            }
        }
    }

    /// Runs a search against Gmail and keeps what comes back.
    func search(_ text: String, mode: SearchMode) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isConnected else { return }

        isSearchingRemotely = true
        searchError = nil
        defer { isSearchingRemotely = false }

        var gmailQuery = trimmed
        var terms = Highlight.terms(in: trimmed)
        var explanation: String?

        if mode == .ai {
            do {
                let plan = try await AIService.searchPlan(for: trimmed)
                if !plan.query.isEmpty { gmailQuery = plan.query }
                if !plan.terms.isEmpty { terms = plan.terms }
                explanation = plan.explanation
            } catch {
                // Fall back to searching for exactly what they typed rather
                // than failing. A worse search beats no search.
                searchError = "Maily could not read that, so this is a plain search."
            }
        }

        do {
            let token = try await AuthService.currentGmailAccessToken()
            let page = try await GmailService.fetchInbox(
                accessToken: token,
                limit: Self.searchPageSize,
                query: gmailQuery,
                // The whole account. A search that only looks in the inbox
                // cannot find the thing you sent.
                label: nil
            )

            absorb(page.messages)
            searchResults = page.messages
            searchTerms = terms
            searchExplanation = explanation
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// The same reach the search box has, for the assistant.
    ///
    /// Retrieval in the chat only ever looked at the three months this phone
    /// holds, so "what did the landlord send about the deposit" came back as
    /// "nothing in your recent mail covers that" when the answer was sitting
    /// in the account all along. This runs the question through the same
    /// query planner the AI search uses and hands the results back, without
    /// touching the search screen's state.
    ///
    /// Returns nothing rather than throwing: an assistant that loses a whole
    /// answer because one lookup failed is worse than one that answers from
    /// what it already had.
    func olderMail(matching question: String, limit: Int = 8) async -> (messages: [Message], searchedFor: String?) {
        guard isConnected else { return ([], nil) }

        var explanation: String?
        var terms: [String] = []
        var planned: String?
        if let plan = try? await AIService.searchPlan(for: question), !plan.query.isEmpty {
            planned = plan.query
            explanation = plan.explanation
            terms = plan.terms
        }

        guard let token = try? await AuthService.currentGmailAccessToken() else { return ([], nil) }

        for query in Self.widening(from: planned, terms: terms, raw: question) {
            guard let page = try? await GmailService.fetchInbox(
                accessToken: token, limit: limit, query: query, label: nil
            ) else { continue }
            guard !page.messages.isEmpty else { continue }

            absorb(page.messages)
            return (page.messages, explanation)
        }

        return ([], explanation)
    }

    /// The same search, tried progressively less strictly.
    ///
    /// Gmail joins bare words with AND. "Upwork welcome registration account
    /// created" therefore means *all five* words in one email, and the actual
    /// Welcome to Upwork message contains neither "registration" nor
    /// "created" -- so a search that ran perfectly was guaranteed to find
    /// nothing, and the answer came back "not in your mail" about an email
    /// sitting in the account.
    ///
    /// So: the exact query first, then the same words as alternatives, then
    /// the single most distinctive one. Something too broad can be read; a
    /// perfect query matching nothing cannot.
    static func widening(from planned: String?, terms: [String], raw: String) -> [String] {
        var attempts: [String] = []
        if let planned, !planned.isEmpty { attempts.append(planned) }

        let source = terms.isEmpty ? raw.components(separatedBy: " ") : terms
        let words = source
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return attempts }

        if words.count > 1 {
            attempts.append(words.joined(separator: " OR "))
        }
        // The longest word is the one carrying the question: "registration"
        // rather than "account". On its own it is broad, and broad is
        // readable.
        if let longest = words.max(by: { $0.count < $1.count }) {
            attempts.append(longest)
        }

        var seen = Set<String>()
        return attempts.filter { seen.insert($0.lowercased()).inserted }
    }

    func clearSearch() {
        searchResults = []
        searchTerms = []
        searchExplanation = nil
        searchError = nil
    }

    /// Forty is a screenful and a half. Gmail charges a request per message
    /// body, so this is the number that makes search feel instant without
    /// fetching a hundred emails nobody scrolls to.
    static var searchPageSize: Int { 40 }
}
