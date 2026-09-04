import Foundation

/// One IMAP conversation.
///
/// An `actor` so commands cannot overlap. IMAP tags exist precisely so a
/// client *can* have several in flight, but nothing in this app needs that and
/// interleaved responses are where hand-written IMAP clients go wrong. One
/// command at a time, its answer read to completion, then the next.
///
/// Safe as an actor only because `MailStream` does its blocking on a GCD
/// queue. If that ever changes this becomes a pool-starvation bug rather than
/// a design choice -- see the note at the top of `MailStream`.
actor IMAPConnection {

    enum Failure: LocalizedError {
        case rejected(command: String, reason: String)
        case passwordRefused
        case loginDisabled
        case noSuchFolder(String)
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let command, let reason):
                "The server refused \(command): \(reason)"
            case .passwordRefused:
                "The server did not accept that username and password."
            case .loginDisabled:
                "This server will not accept a password on an unencrypted connection. Try SSL/TLS."
            case .noSuchFolder(let name):
                "The folder \(name) is not there."
            case .unexpected(let what):
                "Unexpected reply from the server: \(what)"
            }
        }
    }

    /// What came back from one command.
    struct Reply {
        /// The `*` lines -- the actual content of most responses.
        var untagged: [String]
        /// The tagged line that ended it.
        var completion: String
        var isOK: Bool

        /// The text after `OK` / `NO` / `BAD`, which is what a server puts its
        /// reason in.
        var reason: String {
            let parts = completion.split(separator: " ", maxSplits: 2).map(String.init)
            return parts.count > 2 ? parts[2] : completion
        }
    }

    private let stream: MailStream
    private let security: TransportSecurity
    private var tag = 0
    private(set) var capabilities: Set<String> = []

    init(host: String, port: Int, security: TransportSecurity) {
        self.stream = MailStream(host: host, port: port)
        self.security = security
    }

    // MARK: - The session

    /// Connects, secures, and reads the greeting.
    func open() async throws {
        try await stream.open(secure: security == .tls)

        // Every IMAP server opens by introducing itself. Reading it is not
        // optional -- leave it in the buffer and the first command's response
        // is one line out of step for the rest of the session.
        let greeting = try await responseLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw Failure.unexpected(greeting)
        }

        try await loadCapabilities()

        if security == .startTLS {
            guard capabilities.contains("STARTTLS") else {
                throw Failure.rejected(command: "STARTTLS", reason: "the server does not offer it")
            }
            _ = try await command("STARTTLS")
            try await stream.upgradeToTLS()
            // Anything learned before the upgrade was learned in the clear and
            // a server is entitled to answer differently now. RFC 3501 says to
            // ask again, and servers that hide LOGIN until secured rely on it.
            try await loadCapabilities()
        }
    }

    func close() async {
        _ = try? await command("LOGOUT")
        await stream.close()
    }

    private func loadCapabilities() async throws {
        let reply = try await command("CAPABILITY")
        capabilities = Set(
            reply.untagged
                .filter { $0.uppercased().hasPrefix("* CAPABILITY") }
                .flatMap { $0.dropFirst("* CAPABILITY".count).split(separator: " ") }
                .map { $0.uppercased() }
        )
    }

    // MARK: - Signing in

    func login(username: String, password: String) async throws {
        if capabilities.contains("LOGINDISABLED") { throw Failure.loginDisabled }

        // Built as arguments rather than interpolated, so a password holding a
        // quote or a backslash is escaped rather than ending the string early.
        let reply = try await command("LOGIN", arguments: [username, password])
        guard reply.isOK else { throw Failure.passwordRefused }

        // The capability list changes on login -- servers advertise far less
        // to a stranger -- and what matters later (UIDPLUS, MOVE, SPECIAL-USE)
        // is only in the second answer.
        if let inline = reply.untagged.first(where: { $0.uppercased().hasPrefix("* CAPABILITY") }) {
            capabilities = Set(
                inline.dropFirst("* CAPABILITY".count)
                    .split(separator: " ")
                    .map { $0.uppercased() }
            )
        } else {
            try await loadCapabilities()
        }
    }

    // MARK: - Folders

    /// One folder as the server describes it.
    struct Folder: Hashable, Sendable {
        var name: String
        /// `\Sent`, `\Drafts`, `\Trash`, `\Junk`, `\All` where the server says
        /// so. RFC 6154, and the only reliable way to find the Sent folder --
        /// its *name* is localised, and guessing at "Sent Items" against
        /// "Éléments envoyés" is how a client ends up creating a second one.
        var attributes: Set<String>
        /// What separates a parent from a child here. Usually "/" or ".".
        var delimiter: String

        var isSelectable: Bool { !attributes.contains("\\NOSELECT") }
    }

    func folders() async throws -> [Folder] {
        let reply = try await command("LIST", arguments: ["", "*"])
        guard reply.isOK else {
            throw Failure.rejected(command: "LIST", reason: reply.reason)
        }
        return reply.untagged.compactMap(Self.parseListLine)
    }

    /// `* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail"`
    static func parseListLine(_ line: String) -> Folder? {
        guard line.uppercased().hasPrefix("* LIST ") else { return nil }

        var rest = Substring(line.dropFirst("* LIST ".count))

        guard rest.first == "(", let close = rest.firstIndex(of: ")") else { return nil }
        let attributes = Set(
            rest[rest.index(after: rest.startIndex)..<close]
                .split(separator: " ")
                .map { $0.uppercased() }
        )
        rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })

        // The delimiter is a quoted character, or NIL for a flat namespace.
        var delimiter = "/"
        if rest.uppercased().hasPrefix("NIL") {
            rest = rest.dropFirst(3)
        } else if rest.first == "\"" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            // Written as "\\" on the wire when it is a backslash.
            delimiter = String(body[body.startIndex..<end]).replacingOccurrences(of: "\\\\", with: "\\")
            rest = body[body.index(after: end)...]
        }
        rest = rest.drop(while: { $0 == " " })

        let name = unquote(String(rest))
        guard !name.isEmpty else { return nil }
        return Folder(name: name, attributes: attributes, delimiter: delimiter)
    }

    // MARK: - Sending a command

    /// Sends a command and reads everything it produced.
    ///
    /// Arguments are quoted here rather than by the caller. That is not
    /// tidiness: a password is an argument, passwords contain quotes and
    /// backslashes, and a client that interpolates them straight into the
    /// command line breaks on exactly the passwords people were told to use.
    @discardableResult
    func command(_ name: String, arguments: [String] = []) async throws -> Reply {
        tag += 1
        let label = "a\(String(format: "%04d", tag))"

        // An argument that cannot be quoted is sent as a literal, which the
        // server has to invite before it will read it.
        var line = "\(label) \(name)"
        var pending: [String] = []
        for argument in arguments {
            if let quoted = Self.quoted(argument) {
                line += " \(quoted)"
            } else {
                line += " {\(argument.utf8.count)}"
                pending.append(argument)
            }
        }

        try await stream.send(line)

        for (index, literal) in pending.enumerated() {
            let go = try await responseLine()
            guard go.hasPrefix("+") else {
                throw Failure.rejected(command: name, reason: go)
            }
            // Everything after a literal is the rest of the same command line,
            // so the tail follows the bytes without a break.
            let isLast = index == pending.count - 1
            try await stream.send(Data(literal.utf8))
            if !isLast { try await stream.send("") }
        }
        if !pending.isEmpty { try await stream.send("") }

        return try await readReply(tag: label)
    }

    private func readReply(tag label: String) async throws -> Reply {
        var untagged: [String] = []

        while true {
            let line = try await responseLine()

            if line.hasPrefix("\(label) ") {
                let verdict = line
                    .dropFirst(label.count + 1)
                    .prefix(while: { $0 != " " })
                    .uppercased()
                return Reply(untagged: untagged, completion: line, isOK: verdict == "OK")
            }

            // A `+` outside a literal exchange is a server asking for
            // something this client did not offer to give. Answering with an
            // empty line cancels it, which is better than deadlocking.
            if line.hasPrefix("+") {
                try await stream.send("")
                continue
            }

            untagged.append(line)
        }
    }

    /// One logical response line, with any literals folded into it.
    ///
    /// `{123}` at the end of a line means the next 123 bytes are part of this
    /// response and are not a line at all -- they routinely contain CRLF,
    /// which is the whole reason literals exist.
    private func responseLine() async throws -> String {
        var line = try await stream.line()

        while let length = Self.literalLength(atEndOf: line) {
            let data = try await stream.bytes(length)
            line += String(decoding: data, as: UTF8.self)
            line += try await stream.line()
        }
        return line
    }

    // MARK: - Wire formatting

    /// `{123}` or `{123+}` at the very end of a line, and the count in it.
    static func literalLength(atEndOf line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        // A non-synchronising literal, which arrives without waiting for `+`.
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        return Int(digits)
    }

    /// An IMAP quoted string, or nil when the value cannot be one.
    ///
    /// CR and LF cannot appear in a quoted string at all, and anything outside
    /// ASCII is safer sent by length than by quoting. Both go as literals.
    static func quoted(_ value: String) -> String? {
        guard !value.contains("\r"), !value.contains("\n"), value.allSatisfy(\.isASCII) else {
            return nil
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Takes the quotes off a server-sent string, undoing its escapes.
    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
