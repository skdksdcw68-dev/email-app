import XCTest
@testable import EmailApp

/// The wire format, checked where it can be: the pure parsing and quoting.
///
/// The socket itself cannot be tested in CI -- there is no server to talk to
/// -- so what is testable is everything that decides *what gets sent* and what
/// a reply means. Those are also where the bugs are: an unescaped password, a
/// literal counted wrong, a folder name with a space in it.
final class IMAPTests: XCTestCase {

    // MARK: - Quoting

    func testAPlainArgumentIsQuoted() {
        XCTAssertEqual(IMAPConnection.quoted("INBOX"), "\"INBOX\"")
    }

    func testAPasswordWithAQuoteIsEscaped() {
        // 🔴 The bug this exists for: interpolating a password straight into
        // the command line ends the string early and the login fails for
        // exactly the passwords people were told to use.
        XCTAssertEqual(IMAPConnection.quoted("pa\"ss"), "\"pa\\\"ss\"")
    }

    func testAPasswordWithABackslashIsEscaped() {
        XCTAssertEqual(IMAPConnection.quoted("pa\\ss"), "\"pa\\\\ss\"")
    }

    func testSomethingUnquotableFallsBackToALiteral() {
        // Returning nil is the signal to send it by length instead.
        XCTAssertNil(IMAPConnection.quoted("pa\r\nss"))
        XCTAssertNil(IMAPConnection.quoted("pässword"))
    }

    func testUnquotingUndoesIt() {
        XCTAssertEqual(IMAPConnection.unquote("\"Sent Items\""), "Sent Items")
        XCTAssertEqual(IMAPConnection.unquote("\"a\\\"b\""), "a\"b")
        XCTAssertEqual(IMAPConnection.unquote("INBOX"), "INBOX")
    }

    // MARK: - Literals

    func testItFindsALiteralLength() {
        XCTAssertEqual(IMAPConnection.literalLength(atEndOf: "* 1 FETCH (BODY[] {1234}"), 1234)
    }

    func testItAcceptsANonSynchronisingLiteral() {
        XCTAssertEqual(IMAPConnection.literalLength(atEndOf: "a001 LOGIN {12+}"), 12)
    }

    func testALineWithNoLiteralHasNoLength() {
        XCTAssertNil(IMAPConnection.literalLength(atEndOf: "a001 OK LOGIN completed"))
        // Braces that are not a count -- a subject can contain anything.
        XCTAssertNil(IMAPConnection.literalLength(atEndOf: "* 1 FETCH (SUBJECT {hello}"))
    }

    // MARK: - LIST

    func testItParsesAFolder() throws {
        let folder = try XCTUnwrap(
            IMAPConnection.parseListLine("* LIST (\\HasNoChildren) \"/\" \"INBOX\"")
        )
        XCTAssertEqual(folder.name, "INBOX")
        XCTAssertEqual(folder.delimiter, "/")
        XCTAssertTrue(folder.isSelectable)
    }

    func testItParsesAFolderNameWithSpaces() throws {
        let folder = try XCTUnwrap(
            IMAPConnection.parseListLine("* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Sent Mail\"")
        )
        XCTAssertEqual(folder.name, "[Gmail]/Sent Mail")
        XCTAssertTrue(folder.attributes.contains("\\SENT"))
    }

    func testItParsesADotDelimiter() throws {
        // Courier and Dovecot commonly use "." rather than "/".
        let folder = try XCTUnwrap(
            IMAPConnection.parseListLine("* LIST (\\HasChildren) \".\" \"INBOX.Archive\"")
        )
        XCTAssertEqual(folder.delimiter, ".")
        XCTAssertEqual(folder.name, "INBOX.Archive")
    }

    func testANilDelimiterIsHandled() throws {
        let folder = try XCTUnwrap(
            IMAPConnection.parseListLine("* LIST (\\HasNoChildren) NIL \"Flat\"")
        )
        XCTAssertEqual(folder.name, "Flat")
    }

    func testAnUnselectableFolderSaysSo() throws {
        // "[Gmail]" is a container, not a folder. Selecting it is an error.
        let folder = try XCTUnwrap(
            IMAPConnection.parseListLine("* LIST (\\Noselect \\HasChildren) \"/\" \"[Gmail]\"")
        )
        XCTAssertFalse(folder.isSelectable)
    }

    func testSomethingThatIsNotAListLineIsIgnored() {
        XCTAssertNil(IMAPConnection.parseListLine("* OK [UIDVALIDITY 1] UIDs valid"))
        XCTAssertNil(IMAPConnection.parseListLine("a001 OK LIST completed"))
    }

    // MARK: - Guessing the server

    func testAKnownProviderIsRecognised() {
        let guess = MailServerGuess.first(for: "someone@fastmail.com")
        XCTAssertTrue(guess.isKnownHost)
        XCTAssertEqual(guess.config.imapHost, "imap.fastmail.com")
        // Fastmail refuses an account password, so the app has to say so
        // before somebody tries theirs three times.
        XCTAssertNotNil(guess.warning)
    }

    func testACustomDomainFollowsTheConvention() {
        let guess = MailServerGuess.first(for: "abel@somecompany.co.uk")
        XCTAssertFalse(guess.isKnownHost)
        XCTAssertEqual(guess.config.imapHost, "imap.somecompany.co.uk")
        XCTAssertEqual(guess.config.smtpHost, "smtp.somecompany.co.uk")
        XCTAssertEqual(guess.config.username, "abel@somecompany.co.uk")
    }

    func testTheAddressIsCanonicalisedFirst() {
        let guess = MailServerGuess.first(for: "  Abel@Example.COM ")
        XCTAssertEqual(guess.config.username, "abel@example.com")
        XCTAssertEqual(guess.config.imapHost, "imap.example.com")
    }

    func testAKnownProviderFillsInItsPorts() {
        // Outlook is the case where the ports differ from the common pair:
        // 993 in, but 587 with STARTTLS out rather than 465.
        let guess = MailServerGuess.first(for: "someone@outlook.com")
        XCTAssertEqual(guess.config.imapPort, 993)
        XCTAssertEqual(guess.config.smtpPort, 587)
        XCTAssertEqual(guess.config.smtpSecurity, .startTLS)
    }

    func testTheFieldsAreNeverLeftEmpty() {
        // Whatever the domain, the form opens with something to correct
        // rather than four blank boxes.
        let guess = MailServerGuess.first(for: "onboarding@drobefashion.com")
        XCTAssertFalse(guess.config.imapHost.isEmpty)
        XCTAssertFalse(guess.config.smtpHost.isEmpty)
        XCTAssertFalse(guess.config.username.isEmpty)
    }

    func testProtonIsCalledOutRatherThanQuietlyFailing() {
        // Proton does not speak IMAP to anything but its own Bridge, which
        // runs on a computer. A phone cannot reach it and never will, so the
        // honest thing is to say that instead of timing out.
        let guess = MailServerGuess.first(for: "someone@proton.me")
        XCTAssertNotNil(guess.warning)
        XCTAssertTrue(guess.warning?.contains("Bridge") == true)
    }
}
