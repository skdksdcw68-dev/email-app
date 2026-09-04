import Foundation

/// What to put in the server fields before anybody types.
///
/// Not a search -- the app asks for the server the way Gmail's own app does,
/// and this only decides what those fields say when the screen opens. A known
/// provider fills in correctly and the person presses Sign in; an unknown
/// domain gets `imap.` and `smtp.`, which is the convention most hosts follow
/// and is easy to correct when it is wrong.
///
/// The difference from the version this replaced is who chooses. Guessing in
/// the *fields* is free: it is visible, and it is edited before anything is
/// dialled. Guessing at the *connection* was not -- it took minutes, and a
/// failure could not say which server had refused.
///
/// ⚠️ Deliberately offline. Thunderbird's autoconfig service would answer more
/// of these, and it would mean posting the person's mail domain to Mozilla
/// before they have connected anything. For a business mailbox the domain
/// *is* the company.
enum MailServerGuess {

    /// A guess, and how much faith to put in it.
    struct Guess {
        var config: IMAPConfig
        /// True when this came from the table rather than from a pattern, in
        /// which case the settings screen can stay closed.
        var isKnownHost: Bool
        /// Something the person needs to know before they try -- an app
        /// password requirement, usually.
        var warning: String?
    }

    /// Hosts worth knowing by name, because their servers are not named after
    /// their domains and no pattern would find them.
    private struct Known {
        var imap: String
        var imapPort = 993
        var smtp: String
        var smtpPort = 465
        var smtpSecurity: TransportSecurity = .tls
        /// Whether the username is the whole address or just the local part.
        /// Almost always the address; the exceptions are what this is for.
        var usernameIsAddress = true
        var warning: String?
    }

    private static let table: [String: Known] = [
        "gmail.com": Known(
            imap: "imap.gmail.com", smtp: "smtp.gmail.com",
            warning: "Google needs an App Password here, not your normal one. Sign in with Google instead if you can — it is safer and it does not need one."
        ),
        "googlemail.com": Known(imap: "imap.gmail.com", smtp: "smtp.gmail.com"),

        "outlook.com": Known(imap: "outlook.office365.com", smtp: "smtp.office365.com", smtpPort: 587, smtpSecurity: .startTLS),
        "hotmail.com": Known(imap: "outlook.office365.com", smtp: "smtp.office365.com", smtpPort: 587, smtpSecurity: .startTLS),
        "live.com":    Known(imap: "outlook.office365.com", smtp: "smtp.office365.com", smtpPort: 587, smtpSecurity: .startTLS),
        "msn.com":     Known(imap: "outlook.office365.com", smtp: "smtp.office365.com", smtpPort: 587, smtpSecurity: .startTLS),

        "yahoo.com":   Known(imap: "imap.mail.yahoo.com", smtp: "smtp.mail.yahoo.com",
                             warning: "Yahoo needs an App Password, generated in your Yahoo account security settings."),
        "aol.com":     Known(imap: "imap.aol.com", smtp: "smtp.aol.com"),

        "icloud.com":  Known(imap: "imap.mail.me.com", smtp: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS,
                             warning: "iCloud needs an app-specific password from appleid.apple.com."),
        "me.com":      Known(imap: "imap.mail.me.com", smtp: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS),
        "mac.com":     Known(imap: "imap.mail.me.com", smtp: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS),

        "zoho.com":    Known(imap: "imap.zoho.com", smtp: "smtp.zoho.com"),
        "zohomail.com": Known(imap: "imap.zoho.com", smtp: "smtp.zoho.com"),
        "fastmail.com": Known(imap: "imap.fastmail.com", smtp: "smtp.fastmail.com",
                              warning: "Fastmail needs an app password, created under Settings → Privacy & Security."),
        "yandex.com":  Known(imap: "imap.yandex.com", smtp: "smtp.yandex.com"),
        "gmx.com":     Known(imap: "imap.gmx.com", smtp: "mail.gmx.com"),
        "mail.com":    Known(imap: "imap.mail.com", smtp: "smtp.mail.com"),

        // Shared hosting, where a lot of small-business mail actually is.
        "privateemail.com": Known(imap: "mail.privateemail.com", smtp: "mail.privateemail.com"),

        "protonmail.com": Known(
            imap: "127.0.0.1", imapPort: 1143, smtp: "127.0.0.1", smtpPort: 1025, smtpSecurity: .startTLS,
            warning: "Proton does not allow other apps to connect directly. It only works through Proton Bridge on a computer, which a phone cannot reach."
        ),
        "proton.me": Known(
            imap: "127.0.0.1", imapPort: 1143, smtp: "127.0.0.1", smtpPort: 1025, smtpSecurity: .startTLS,
            warning: "Proton does not allow other apps to connect directly. It only works through Proton Bridge on a computer, which a phone cannot reach."
        ),
    ]

    /// What the fields open with.
    static func first(for address: String) -> Guess {
        let canonical = MailboxID.canonical(address)
        let domain = String(canonical.split(separator: "@").last ?? "")

        if let known = table[domain] {
            return Guess(
                config: IMAPConfig(
                    imapHost: known.imap,
                    imapPort: known.imapPort,
                    smtpHost: known.smtp,
                    smtpPort: known.smtpPort,
                    username: known.usernameIsAddress ? canonical : String(canonical.split(separator: "@").first ?? ""),
                    imapSecurity: .tls,
                    smtpSecurity: known.smtpSecurity
                ),
                isKnownHost: true,
                warning: known.warning
            )
        }

        // The convention almost every host follows for a custom domain. Wrong
        // often enough that the fields are shown, right often enough to be
        // worth filling in first.
        return Guess(
            config: IMAPConfig(
                imapHost: "imap.\(domain)",
                imapPort: 993,
                smtpHost: "smtp.\(domain)",
                smtpPort: 465,
                username: canonical,
                imapSecurity: .tls,
                smtpSecurity: .tls
            ),
            isKnownHost: false,
            warning: nil
        )
    }
}
