import Foundation

/// Sending, for a mailbox that is not Gmail.
///
/// Much smaller than IMAP: greet, say who you are, authenticate, name the
/// sender and the recipients, then post the message. The whole protocol worth
/// implementing is about eight commands.
///
/// `MIMEBuilder` already produces exactly what goes in `DATA`, so this does
/// not build messages -- it delivers one.
actor SMTPConnection {

    enum Failure: LocalizedError {
        case rejected(String)
        case authRefused
        case noAuthMethod
        case tooBig(limit: Int)

        var errorDescription: String? {
            switch self {
            case .rejected(let reason): "The mail server refused it: \(reason)"
            case .authRefused: "The mail server did not accept that username and password."
            case .noAuthMethod: "The mail server does not offer a sign-in method this app can use."
            case .tooBig(let limit):
                "Too big to send. This server accepts about \(limit / 1_000_000)MB."
            }
        }
    }

    private let stream: MailStream
    private let security: TransportSecurity
    private let host: String

    /// What the server said it can do, from the EHLO reply.
    private(set) var extensions: Set<String> = []
    /// The server's own `SIZE`, which differs per host and is the only honest
    /// source for the attachment limit.
    private(set) var maxSize: Int?

    init(host: String, port: Int, security: TransportSecurity) {
        self.host = host
        self.security = security
        self.stream = MailStream(host: host, port: port)
    }

    // MARK: - The session

    func open() async throws {
        try await stream.open(secure: security == .tls)

        let greeting = try await response()
        guard greeting.code == 220 else { throw Failure.rejected(greeting.text) }

        try await greet()

        if security == .startTLS {
            guard extensions.contains("STARTTLS") else {
                throw Failure.rejected("the server does not offer STARTTLS on this port")
            }
            let go = try await send("STARTTLS")
            guard go.code == 220 else { throw Failure.rejected(go.text) }

            try await stream.upgradeToTLS()
            // Everything learned before the upgrade was learned in the clear,
            // and servers deliberately hide AUTH until the channel is secure.
            try await greet()
        }
    }

    func close() async {
        _ = try? await send("QUIT")
        await stream.close()
    }

    /// EHLO, and the capability list it answers with.
    private func greet() async throws {
        // The argument is meant to be this client's own name. Nothing on a
        // phone has one worth stating, and every server accepts a literal
        // address form for exactly this case.
        let reply = try await send("EHLO [127.0.0.1]")
        guard reply.code == 250 else {
            // A server old enough to refuse EHLO cannot do AUTH or TLS either,
            // and there is nothing useful to fall back to.
            throw Failure.rejected(reply.text)
        }

        extensions = []
        maxSize = nil
        for line in reply.lines.dropFirst() {
            let words = line.split(separator: " ")
            guard let keyword = words.first?.uppercased() else { continue }
            extensions.insert(keyword)

            if keyword == "SIZE", words.count > 1 { maxSize = Int(words[1]) }
            if keyword == "AUTH" {
                for method in words.dropFirst() { extensions.insert("AUTH=\(method.uppercased())") }
            }
        }
    }

    // MARK: - Signing in

    func login(username: String, password: String) async throws {
        if extensions.contains("AUTH=PLAIN") {
            // \0user\0password, base64. One round trip rather than three.
            var payload = Data([0])
            payload.append(Data(username.utf8))
            payload.append(0)
            payload.append(Data(password.utf8))

            let reply = try await send("AUTH PLAIN \(payload.base64EncodedString())")
            guard reply.code == 235 else { throw Failure.authRefused }
            return
        }

        if extensions.contains("AUTH=LOGIN") {
            let start = try await send("AUTH LOGIN")
            guard start.code == 334 else { throw Failure.authRefused }

            let user = try await send(Data(username.utf8).base64EncodedString())
            guard user.code == 334 else { throw Failure.authRefused }

            let pass = try await send(Data(password.utf8).base64EncodedString())
            guard pass.code == 235 else { throw Failure.authRefused }
            return
        }

        throw Failure.noAuthMethod
    }

    // MARK: - Delivering

    /// One message to one set of recipients.
    ///
    /// Bcc recipients are named here and **must not** be in the message text.
    /// `MIMEBuilder` writes a `Bcc:` header, which is right for a draft and
    /// wrong for a delivery -- the envelope is what actually routes mail, and
    /// a Bcc header that reaches the server tells every recipient who was
    /// blind-copied. Stripping it is not tidiness, it is the whole point of
    /// the feature.
    func deliver(raw: Data, from sender: String, to recipients: [String]) async throws {
        if let maxSize, raw.count > maxSize {
            throw Failure.tooBig(limit: maxSize)
        }

        let from = try await send("MAIL FROM:<\(sender)>")
        guard from.code == 250 else { throw Failure.rejected(from.text) }

        for recipient in recipients {
            let reply = try await send("RCPT TO:<\(recipient)>")
            // 251 is "not local, will forward", which is a yes.
            guard reply.code == 250 || reply.code == 251 else {
                throw Failure.rejected("\(recipient) was refused: \(reply.text)")
            }
        }

        let data = try await send("DATA")
        guard data.code == 354 else { throw Failure.rejected(data.text) }

        try await stream.send(Self.dotStuffed(raw))
        let done = try await send(".")
        guard done.code == 250 else { throw Failure.rejected(done.text) }
    }

    /// A line of the message that is just "." would end it early.
    ///
    /// The fix is as old as the protocol: any line starting with "." gets a
    /// second one, and the receiver takes it off. Without this, a message
    /// containing such a line is truncated there and the rest is interpreted
    /// as commands.
    static func dotStuffed(_ raw: Data) -> Data {
        var out = Data()
        out.reserveCapacity(raw.count + 64)

        var atLineStart = true
        for byte in raw {
            if atLineStart && byte == UInt8(ascii: ".") { out.append(byte) }
            out.append(byte)
            atLineStart = byte == UInt8(ascii: "\n")
        }
        // The terminator has to begin its own line.
        if !atLineStart { out.append(contentsOf: Array("\r\n".utf8)) }
        return out
    }

    // MARK: - The wire

    struct Reply {
        var code: Int
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    @discardableResult
    private func send(_ line: String) async throws -> Reply {
        try await stream.send(line)
        return try await response()
    }

    /// SMTP replies are `250-first` for every line but the last, which is
    /// `250 last`. The space is the only thing that says it is over.
    private func response() async throws -> Reply {
        var lines: [String] = []
        var code = 0

        while true {
            let line = try await stream.line()
            code = Int(line.prefix(3)) ?? code

            let body = String(line.dropFirst(3))
            lines.append(body.hasPrefix("-") || body.hasPrefix(" ")
                ? String(body.dropFirst())
                : body)

            if !body.hasPrefix("-") { return Reply(code: code, lines: lines) }
        }
    }
}
