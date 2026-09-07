import XCTest
@testable import EmailApp

/// The rule under test is not "every error has a nice sentence". It is that
/// **nothing an SDK wrote reaches a screen unread**: no status codes, no
/// domains, no JSON, no "the operation couldn't be completed".
@MainActor
final class HumanErrorTests: XCTestCase {

    /// Everything a person could be shown has to pass this.
    private func assertHuman(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.isEmpty, "an empty error tells nobody anything", file: file, line: line)
        for banned in ["Error Domain", "NSError", "NSURLError", "{", "}", "nil"] {
            XCTAssertFalse(text.contains(banned), "'\(banned)' in: \(text)", file: file, line: line)
        }
        XCTAssertNil(text.range(of: #"\b\d{3}\b"#, options: .regularExpression),
                     "a bare status code in: \(text)", file: file, line: line)
        XCTAssertTrue(text.count < 200, "too long to read on a phone: \(text)", file: file, line: line)
    }

    // MARK: - The network

    func testBeingOfflineSaysSoAndSaysWhatHappensNext() {
        let text = URLError(.notConnectedToInternet).readable
        XCTAssertTrue(text.lowercased().contains("offline"), text)
        assertHuman(text)
    }

    func testATimeoutIsWorthRetrying() {
        assertHuman(URLError(.timedOut).readable)
        XCTAssertTrue(URLError(.timedOut).readable.contains("Try again"))
    }

    func testAnUnmappedNetworkFailureStillReadsLikeASentence() {
        assertHuman(URLError(.unknown).readable)
    }

    // MARK: - What the SDKs actually hand over

    /// The exact string that was reaching labels before this existed. A
    /// neutral domain on purpose -- a real `NSURLErrorDomain` error bridges to
    /// `URLError` and gets the far better sentence above; this is the shape
    /// that arrives from every *other* SDK.
    func testApplesStockSentenceIsNeverShown() {
        let stock = NSError(
            domain: "com.example.sdk",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey:
                "The operation couldn't be completed. (NSURLErrorDomain error -1009.)"]
        )
        XCTAssertEqual(stock.readable, HumanError.generic)
        assertHuman(stock.readable)
    }

    func testAJSONBodyIsNeverShown() {
        let body = NSError(domain: "Gmail", code: 1, userInfo: [
            NSLocalizedDescriptionKey: #"{"error":{"code":500,"status":"INTERNAL"}}"#
        ])
        XCTAssertEqual(body.readable, HumanError.generic)
    }

    func testALogLineIsNeverShown() {
        let long = String(repeating: "stack frame 41 in module EmailApp ", count: 12)
        let error = NSError(domain: "x", code: 2, userInfo: [NSLocalizedDescriptionKey: long])
        XCTAssertEqual(error.readable, HumanError.generic)
    }

    // MARK: - The phrasebook

    func testSupabaseCredentialFailureBecomesSomethingToDo() {
        // 🔴 Abel signed in with Apple and was told, by a Supabase string, to
        // sign up first. Server text is written for a server log.
        let supabase = NSError(domain: "AuthApiError", code: 400, userInfo: [
            NSLocalizedDescriptionKey: "Invalid login credentials"
        ])
        XCTAssertTrue(supabase.readable.contains("don't match"), supabase.readable)
        assertHuman(supabase.readable)
    }

    func testAnAccountThatAlreadyExistsPointsAtSigningIn() {
        let supabase = NSError(domain: "AuthApiError", code: 422, userInfo: [
            NSLocalizedDescriptionKey: "User already registered"
        ])
        XCTAssertTrue(supabase.readable.lowercased().contains("sign in"), supabase.readable)
    }

    func testAnExpiredGrantSaysToConnectAgain() {
        let google = NSError(domain: "OAuth", code: 400, userInfo: [
            NSLocalizedDescriptionKey: "invalid_grant: Token has been expired or revoked."
        ])
        XCTAssertTrue(google.readable.lowercased().contains("connect"), google.readable)
    }

    // MARK: - Ours

    func testGmailStatusCodesNeverReachTheScreen() {
        for code in [401, 403, 404, 413, 429, 500, 418] {
            let text = GmailService.ServiceError.http(code, #"{"error":"whatever"}"#).readable
            assertHuman(text)
            XCTAssertFalse(text.contains("\(code)"), text)
        }
    }

    func testAPermissionFailureSaysToConnectTheMailboxAgain() {
        let text = GmailService.ServiceError.http(401, "").readable
        XCTAssertTrue(text.lowercased().contains("connect it again"), text)
    }

    func testPostgrestDetailIsKeptForLogsAndNotForPeople() {
        let error = Backend.BackendError.server(
            status: 409,
            detail: #"duplicate key value violates unique constraint "user_settings_pkey""#
        )
        XCTAssertEqual(error.detail?.contains("user_settings_pkey"), true)
        XCTAssertFalse(error.readable.contains("user_settings_pkey"))
        assertHuman(error.readable)
    }

    func testOurOwnSentencesArePassedThroughUntouched() {
        // The whole point of writing them: `HumanError` must not flatten a
        // good message into the generic one.
        let error = MailStore.SendError.notConnected
        XCTAssertEqual(error.readable, "Connect a Gmail account before sending.")
    }

    func testTheSpendMessageFromTheEdgeFunctionSurvives() {
        // Metering is the one place where the server's own words are the best
        // words -- they carry the person's allowance.
        let text = "You've used this month's AI allowance. It resets on the 1st."
        XCTAssertEqual(AIService.AIError.server(text).readable, text)
    }

    // MARK: - Cancelling

    func testBackingOutOfASheetIsNotAFailure() {
        let cancelled = NSError(domain: "com.google.GIDSignIn", code: -5)
        XCTAssertTrue(cancelled.isCancellation)
        XCTAssertTrue(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled).isCancellation)
        XCTAssertTrue(CancellationError().isCancellation)
        XCTAssertFalse(URLError(.timedOut).isCancellation)
    }
}
