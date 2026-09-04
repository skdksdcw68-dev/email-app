import Foundation

/// Checking that a mailbox can send, before promising it can.
///
/// Its own check, and its own screen, because sending is genuinely a separate
/// thing: a different host, a different port, a different encryption setting,
/// and at plenty of providers a different password. Folding it into the IMAP
/// check would mean one long form that can only report "something is wrong"
/// and leave somebody to work out which half of it.
enum SMTPProbe {

    enum Outcome {
        case ok
        case failed(String)
    }

    /// Connects and authenticates. Nothing is sent.
    static func verify(_ config: IMAPConfig, username: String, password: String) async -> Outcome {
        guard await IMAPProbe.resolves(config.smtpHost) else {
            return .failed("There is no server called \(config.smtpHost).")
        }

        let smtp = SMTPConnection(
            host: config.smtpHost,
            port: config.smtpPort,
            security: config.smtpSecurity,
            timeout: IMAPProbe.attemptTimeout
        )

        do {
            try await smtp.open()
            try await smtp.login(username: username, password: password)
            await smtp.close()
            return .ok
        } catch {
            await smtp.close()
            return .failed(error.localizedDescription)
        }
    }
}
