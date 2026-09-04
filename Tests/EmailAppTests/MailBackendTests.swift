import Testing
import Foundation
@testable import EmailApp

/// The protocol is mostly plumbing, and plumbing is proved by the app still
/// working. Two parts carry real logic and are worth checking directly: how a
/// query is rendered for a provider, and what happens to a query a provider
/// cannot read.
struct MailQueryTests {

    // MARK: - Rendering for Gmail

    @Test func afolderBecomesALabelAndNotASearch() {
        // The split matters. Gmail's labelIds is a filter and q is a search,
        // and asking for the inbox through q returns a different, worse
        // answer than asking through the label.
        let rendered = GmailBackend.render(.folder(.inbox))
        #expect(rendered.label == "INBOX")
        #expect(rendered.search == nil)
    }

    @Test func everyFolderHasAnAnswer() {
        for mailbox in Mailbox.allCases {
            let rendered = GmailBackend.render(.folder(mailbox))
            // Archive is the absence of a label in Gmail, so nil is correct
            // there and only there.
            if mailbox == .archive {
                #expect(rendered.label == nil)
            } else {
                #expect(rendered.label != nil, "\(mailbox) has no label")
            }
        }
    }

    @Test func theImportWindowBecomesGmailsOwnSyntax() {
        #expect(GmailBackend.render(.newerThan(months: 3)).search == "newer_than:3m")
        #expect(GmailBackend.render(.newerThan(months: 12)).search == "newer_than:12m")
    }

    @Test func anAndCombinesTermsAndKeepsTheFolderApart() {
        let rendered = GmailBackend.render(.and([
            .folder(.sent),
            .newerThan(months: 6),
            .from("sara@example.com"),
        ]))

        #expect(rendered.label == "SENT")
        #expect(rendered.search == "newer_than:6m from:sara@example.com")
    }

    @Test func anEmptyQueryAsksForEverything() {
        let rendered = GmailBackend.render(.everything)
        #expect(rendered.label == nil)
        #expect(rendered.search == nil)
    }

    @Test func providerSyntaxGoesThroughUntouchedForGmail() {
        // Gmail understands it, so it must not be mangled on the way.
        let raw = "from:sara has:attachment newer_than:2d"
        #expect(GmailBackend.render(.providerRaw(raw)).search == raw)
    }

    // MARK: - What a provider cannot read

    @Test func aQueryKnowsWhenItNeedsSyntaxNotEverybodyHas() {
        #expect(MailQuery.providerRaw("from:sara").usesProviderSyntax)
        #expect(MailQuery.and([.folder(.inbox), .providerRaw("x")]).usesProviderSyntax)
        #expect(!MailQuery.and([.folder(.inbox), .from("sara")]).usesProviderSyntax)
        #expect(!MailQuery.freeText("invoice").usesProviderSyntax)
    }

    @Test func providerSyntaxFallsBackToPlainWords() {
        // A worse search, and a search rather than an error nobody can act
        // on. The operators go; the words a person actually typed stay.
        let stripped = MailQuery.providerRaw("from:sara@example.com invoice march").withoutProviderSyntax
        #expect(stripped == .freeText("invoice march"))
    }

    @Test func strippingReachesInsideAnAnd() {
        let query = MailQuery.and([.folder(.inbox), .providerRaw("has:attachment receipt")])
        #expect(query.withoutProviderSyntax == .and([.folder(.inbox), .freeText("receipt")]))
    }

    @Test func aQueryWithNothingButOperatorsBecomesEmpty() {
        // "from:sara" with the operator gone is nothing at all, and an empty
        // search is honest: it means the backend could not narrow it.
        #expect(MailQuery.providerRaw("from:sara has:attachment").withoutProviderSyntax
                == .freeText(""))
    }

    @Test func aBackendThatReadsTheSyntaxKeepsIt() {
        let backend = GmailBackend(account: sample)
        let raw = MailQuery.providerRaw("from:sara")
        // Gmail says it accepts provider syntax, so nothing is stripped.
        #expect(backend.capabilities.acceptsProviderQuerySyntax)
        #expect(backend.understandable(raw) == raw)
    }

    // MARK: - Capabilities

    @Test func theAttachmentLimitComesFromTheBackendNotAConstant() {
        // Four megabytes is a Gmail JSON-body ceiling, not a fact about
        // email. Graph and SMTP both differ.
        #expect(GmailBackend(account: sample).capabilities.maxOutboundBytes == 4 * 1024 * 1024)
    }

    @Test func abackendIsBoundToOneAccount() {
        // This is what stops a token from the active mailbox being used to
        // fetch a message id belonging to a different one.
        let backend = GmailBackend(account: sample)
        #expect(backend.account.address == "abel@example.com")
    }

    private var sample: MailAccount {
        MailAccount(provider: .gmail, address: "abel@example.com", displayName: "Abel")
    }
}

/// The handles a backend gives out.
struct MailReferenceTests {

    @Test func adraftKeepsItsTwoIdsApart() {
        // Gmail's draft endpoints answer to one id and the rest of the app
        // wants the other. Conflating them is a 404, and the app shipped that
        // bug once already.
        let ref = DraftRef(provider: .gmail, primary: "draft-1", secondary: "msg-9")
        #expect(ref.primary == "draft-1")
        #expect(ref.messageID == "msg-9")
    }

    @Test func aproviderWithOneIdUsesItForBoth() {
        let ref = DraftRef(provider: .microsoft, primary: "graph-1")
        #expect(ref.messageID == "graph-1")
    }

    @Test func acheckpointIsOpaque() {
        // Gmail counts in historyId, Graph in a deltaLink URL, IMAP in
        // UIDVALIDITY:UIDNEXT. The app stores it and hands it back.
        #expect(SyncCheckpoint("12345").token == "12345")
        #expect(SyncCheckpoint("https://graph.microsoft.com/v1.0/…/delta?$deltatoken=abc").token.hasPrefix("https"))
    }

    @Test func anExpiredChangeSetSaysSoRatherThanLookingEmpty() {
        // Three providers, three mechanisms, one meaning: your cursor is
        // worthless, refresh everything. An empty ChangeSet would read as
        // "nothing new", which is the opposite.
        let expired = ChangeSet(isExpired: true)
        #expect(expired.added.isEmpty)
        #expect(expired.isExpired)
    }
}
