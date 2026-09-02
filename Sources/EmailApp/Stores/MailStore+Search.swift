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
