import Foundation

/// Finding a mailbox by trying, rather than by asking.
///
/// The add-account screen collects an address and a password. This turns that
/// into a working connection, or into a specific reason it is not one.
enum IMAPProbe {

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
        /// Something answered and said no. The host is right and the
        /// credentials are not.
        case refused(String)
    }

    /// One configuration, tried for real.
    static func verify(_ config: IMAPConfig, password: String) async -> Outcome {
        let connection = IMAPConnection(
            host: config.imapHost,
            port: config.imapPort,
            security: config.imapSecurity
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
            return .refused(error.localizedDescription)
        }
    }

    /// The whole search: the likely answer first, then the usual suspects.
    ///
    /// 🔴 Stops the moment a server *answers* and rejects the password. Trying
    /// the same password against nine more hosts is how an account gets locked
    /// out, and it would not help -- a refusal means the host was found.
    static func discover(
        address: String,
        password: String,
        onAttempt: @Sendable (String) -> Void = { _ in }
    ) async -> Outcome {
        let first = MailServerGuess.first(for: address)

        onAttempt(first.config.imapHost)
        let opening = await verify(first.config, password: password)
        switch opening {
        case .ok, .refused: return opening
        case .unreachable: break
        }

        var lastReason = "Could not reach \(first.config.imapHost)."

        for candidate in MailServerGuess.alternatives(for: address) where candidate.imapHost != first.config.imapHost {
            onAttempt(candidate.imapHost)
            switch await verify(candidate, password: password) {
            case .ok(let success): return .ok(success)
            case .refused(let reason): return .refused(reason)
            case .unreachable(let reason): lastReason = reason
            }
        }

        return .unreachable(lastReason)
    }
}
