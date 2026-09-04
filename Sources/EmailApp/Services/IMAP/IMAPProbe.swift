import Foundation
import Darwin

/// Checking one server, once.
///
/// ⚠️ This used to *search*: up to eight candidate hosts in turn, thirty
/// seconds apiece, on the theory that nobody should have to know what an IMAP
/// server is. It was a bad trade and it is worth writing down why, because the
/// idea is tempting enough to come back.
///
/// It was slow -- minutes of spinner in the bad case, which is exactly the
/// case where somebody is already unsure it is working. And when it failed it
/// could not say anything useful: a refusal means *a* server said no, but the
/// app had picked that server, so it could not tell "your password is wrong"
/// from "your mailbox is not on the machine I guessed". Those need opposite
/// responses and the search made them identical.
///
/// Gmail's own app just asks. So the fields are asked for, prefilled from the
/// domain, and this dials the one server that was actually typed in.
enum IMAPProbe {

    /// How long one host gets. Short on purpose: a mail server that has not
    /// answered in ten seconds is not going to.
    static let attemptTimeout: TimeInterval = 10

    struct Success: Sendable {
        var config: IMAPConfig
        var folders: [IMAPConnection.Folder]

        /// Where sent mail goes, by the server's own `\Sent` attribute rather
        /// than by guessing at the name. See the note on `Folder.attributes`.
        var sentFolder: String? { special("\\SENT") ?? named(["sent", "sent items", "sent mail"]) }
        var draftsFolder: String? { special("\\DRAFTS") ?? named(["drafts"]) }
        var trashFolder: String? { special("\\TRASH") ?? named(["trash", "deleted items", "bin"]) }
        var junkFolder: String? { special("\\JUNK") ?? named(["junk", "spam", "junk email"]) }

        private func special(_ attribute: String) -> String? {
            folders.first { $0.attributes.contains(attribute) }?.name
        }

        private func named(_ candidates: [String]) -> String? {
            folders.first { folder in
                let leaf = folder.name.split(separator: Character(folder.delimiter)).last.map(String.init)
                    ?? folder.name
                return candidates.contains(leaf.lowercased())
            }?.name
        }
    }

    /// What stopped it, and crucially whether it is worth trying elsewhere.
    enum Outcome {
        case ok(Success)
        /// Nothing answered. The host is probably wrong, so another is worth a go.
        case unreachable(String)
        /// Something answered and said no. Carries the host that said it --
        /// without which "did not accept that username and password" is
        /// unanswerable, because the question is always *which server*.
        case refused(reason: String, host: String)
    }

    // MARK: - The attempt

    static func verify(_ config: IMAPConfig, password: String) async -> Outcome {
        // Nothing to dial if the name does not exist. This is the whole
        // speed-up: most guesses are for hosts that were never there.
        guard await resolves(config.imapHost) else {
            return .unreachable("There is no server called \(config.imapHost).")
        }

        let connection = IMAPConnection(
            host: config.imapHost,
            port: config.imapPort,
            security: config.imapSecurity,
            timeout: attemptTimeout
        )

        do {
            try await connection.open()
        } catch {
            await connection.close()
            return .unreachable(error.localizedDescription)
        }

        do {
            try await connection.login(username: config.username, password: password)
            let folders = try await connection.folders()
            await connection.close()
            return .ok(Success(config: config, folders: folders))
        } catch {
            await connection.close()
            return .refused(reason: error.localizedDescription, host: config.imapHost)
        }
    }

    /// Whether a hostname exists at all.
    ///
    /// `getaddrinfo` blocks, so it runs off the cooperative pool for the same
    /// reason everything else in this folder does.
    static func resolves(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(
                    ai_flags: 0,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                if let result { freeaddrinfo(result) }
                continuation.resume(returning: status == 0)
            }
        }
    }
}
