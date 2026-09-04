import Foundation

/// Working out where somebody's mail actually lives, from their address.
///
/// Nobody knows their IMAP host. They know their email address and their
/// password, and asking for "imap.yourcompany.com, port 993, STARTTLS or
/// SSL/TLS?" is where every other app loses them. So the app guesses, tests
/// the guess for real, and only shows the fields when the guess was wrong.
///
/// ⚠️ Deliberately offline. Thunderbird's autoconfig service would answer more
/// of these, and it would mean posting the person's mail domain to Mozilla
/// before they have connected anything. For a business mailbox the domain
/// *is* the company. A table and a naming convention get most of the way there
/// without telling anybody.
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

    /// Hosting companies whose servers are named after *themselves* rather
    /// than after the customer's domain. A company mailbox at these looks like
    /// `you@yourcompany.com` and connects to the host's server.
    ///
    /// Only reachable by trying, which is what the test button is for -- the
    /// domain gives no clue which of these it is on.
    static let commonHosts: [(label: String, imap: String, smtp: String, smtpPort: Int)] = [
        ("Namecheap", "mail.privateemail.com", "mail.privateemail.com", 465),
        ("Hostinger", "imap.hostinger.com", "smtp.hostinger.com", 465),
        ("GoDaddy", "imap.secureserver.net", "smtpout.secureserver.net", 465),
        ("IONOS", "imap.ionos.com", "smtp.ionos.com", 465),
        ("Rackspace", "secure.emailsrvr.com", "secure.emailsrvr.com", 465),
        ("Microsoft 365", "outlook.office365.com", "smtp.office365.com", 587),
        ("Google Workspace", "imap.gmail.com", "smtp.gmail.com", 465),
    ]

    /// The first thing to try for this address.
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

    /// What else to try when the first guess could not be reached.
    ///
    /// `mail.company.com` is as common as `imap.company.com`, and a shared
    /// host is common again. Trying a handful automatically is the difference
    /// between "it works" and a support conversation about port numbers.
    static func alternatives(for address: String) -> [IMAPConfig] {
        let canonical = MailboxID.canonical(address)
        let domain = String(canonical.split(separator: "@").last ?? "")
        guard table[domain] == nil else { return [] }

        var options: [IMAPConfig] = []

        for host in ["mail.\(domain)", domain, "imap.\(domain)"] {
            options.append(IMAPConfig(
                imapHost: host, imapPort: 993,
                smtpHost: host.replacingOccurrences(of: "imap.", with: "smtp."), smtpPort: 465,
                username: canonical, imapSecurity: .tls, smtpSecurity: .tls
            ))
        }

        for host in commonHosts {
            options.append(IMAPConfig(
                imapHost: host.imap, imapPort: 993,
                smtpHost: host.smtp, smtpPort: host.smtpPort,
                username: canonical, imapSecurity: .tls,
                smtpSecurity: host.smtpPort == 587 ? .startTLS : .tls
            ))
        }

        return options
    }
}
