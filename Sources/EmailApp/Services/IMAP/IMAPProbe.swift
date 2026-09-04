import Foundation
import Darwin

/// Finding a mailbox by trying, rather than by asking.
///
/// The add-account screen collects an address and a password. This turns that
/// into a working connection, or into a specific reason it is not one.
///
/// ⏱️ **Speed is a feature here, and the first version did not have it.** Ten
/// candidate hosts at a thirty second timeout each is five minutes of
/// spinner, which nobody waits through -- and most of those candidates do not
/// exist at all. So a name is resolved before anything is dialled, which
/// takes about a tenth of a second and removes most of the list.
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

    /// Where the search has got to, so the screen can show something moving.
    struct Progress: Sendable {
        var host: String
        var attempt: Int
        var total: Int

        var fraction: Double {
            total > 0 ? Double(attempt) / Double(total) : 0
        }
    }

    // MARK: - One host

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

    // MARK: - The search

    /// The whole search: the likely answer first, then the usual suspects.
    ///
    /// 🔴 Stops the moment a server *answers* and rejects the password. Trying
    /// the same password against nine more hosts is how an account gets locked
    /// out, and it would not help -- a refusal means a host was found.
    ///
    /// Which is exactly why `refused` carries the host it came from. A refusal
    /// can mean the password is wrong, or it can mean the app dialled a real
    /// server that this mailbox is simply not on. Those look identical from
    /// here and only the person signing in can tell them apart -- so the app
    /// says which door it knocked on rather than guessing on their behalf.
    static func discover(
        address: String,
        password: String,
        onProgress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async -> Outcome {
        let first = MailServerGuess.first(for: address)
        let rest = MailServerGuess.alternatives(for: address)
            .filter { $0.imapHost != first.config.imapHost }
        let total = 1 + rest.count

        onProgress(Progress(host: first.config.imapHost, attempt: 1, total: total))
        let opening = await verify(first.config, password: password)
        switch opening {
        case .ok, .refused: return opening
        case .unreachable: break
        }

        var lastReason = "Could not reach \(first.config.imapHost)."

        for (index, candidate) in rest.enumerated() {
            onProgress(Progress(host: candidate.imapHost, attempt: index + 2, total: total))

            switch await verify(candidate, password: password) {
            case .ok(let success): return .ok(success)
            case .refused(let reason, let host): return .refused(reason: reason, host: host)
            case .unreachable(let reason): lastReason = reason
            }
        }

        return .unreachable(lastReason)
    }
}
