import Foundation

/// The live connection behind `IMAPBackend`, and everything stateful about it.
///
/// Separate from the backend because a backend is a value -- it gets created,
/// copied and thrown away freely -- and a TCP connection is emphatically not.
/// Connecting costs a handshake and a login, about a second on a phone
/// network, so the connection is opened once and kept.
///
/// An `actor` so the folder currently selected cannot be changed underneath a
/// fetch that is midway through reading one.
actor IMAPSession {

    private let account: MailAccount
    private let config: IMAPConfig
    private var connection: IMAPConnection?
    private var folderMap: [WellKnown: String] = [:]

    init(account: MailAccount, config: IMAPConfig) {
        self.account = account
        self.config = config
    }

    // MARK: - Message references
    //
    // An IMAP message is identified by a UID that only means anything inside
    // one folder -- UID 42 in INBOX and UID 42 in Sent are different messages.
    // So a `MessageRef` here carries both, and these three keep the format in
    // one place rather than spread across the backend.

    static func reference(folder: String, uid: Int) -> String { "\(folder)\u{1}\(uid)" }

    static func folderPart(of reference: String) -> String {
        String(reference.split(separator: "\u{1}").first ?? "INBOX")
    }

    static func uidPart(of reference: String) -> String {
        let parts = reference.split(separator: "\u{1}")
        return parts.count > 1 ? String(parts[1]) : reference
    }

    // MARK: - Connecting

    /// The live connection, opened and signed in if it is not already.
    private func live() async throws -> IMAPConnection {
        if let connection { return connection }

        guard let password = Keychain.read(.imapPassword, for: account.id) else {
            throw IMAPConnection.Failure.passwordRefused
        }

        let fresh = IMAPConnection(
            host: config.imapHost,
            port: config.imapPort,
            security: config.imapSecurity
        )
        try await fresh.open()
        try await fresh.login(username: config.username, password: password)

        connection = fresh
        return fresh
    }

    /// Runs something against the connection, reopening once if the socket had
    /// gone.
    ///
    /// A phone loses IMAP connections constantly -- the network changes, the
    /// app is backgrounded, the server times out an idle session at thirty
    /// minutes. Every one of those looks like a failed command, and retrying
    /// once on a fresh connection is the difference between "it works" and an
    /// app that has to be reopened after lunch.
    private func retrying<T>(_ work: (IMAPConnection) async throws -> T) async throws -> T {
        do {
            return try await work(try await live())
        } catch let error as MailStream.Failure where error == .closed || error == .timedOut {
            connection = nil
            folderMap = [:]
            return try await work(try await live())
        }
    }

    // MARK: - Folders

    enum WellKnown { case inbox, sent, drafts, trash, junk, archive }

    /// The server's name for one of the folders the app knows about.
    ///
    /// Asked for by RFC 6154 attribute first. A mailbox in French calls its
    /// sent folder "Éléments envoyés" and a client that looks for "Sent"
    /// creates a second one beside it -- which is how people end up with two.
    func wellKnown(_ kind: WellKnown) async throws -> String {
        if let cached = folderMap[kind] { return cached }
        if kind == .inbox { return "INBOX" }

        let folders = try await retrying { try await $0.folders() }

        let attribute: String
        let names: [String]
        switch kind {
        case .inbox:   return "INBOX"
        case .sent:    attribute = "\\SENT";    names = ["sent", "sent items", "sent mail"]
        case .drafts:  attribute = "\\DRAFTS";  names = ["drafts"]
        case .trash:   attribute = "\\TRASH";   names = ["trash", "deleted items", "bin"]
        case .junk:    attribute = "\\JUNK";    names = ["junk", "spam", "junk email"]
        case .archive: attribute = "\\ARCHIVE"; names = ["archive", "all mail"]
        }

        let match = folders.first { $0.attributes.contains(attribute) }
            ?? folders.first { folder in
                let leaf = folder.name
                    .split(separator: Character(folder.delimiter))
                    .last
                    .map(String.init) ?? folder.name
                return names.contains(leaf.lowercased())
            }

        // Falling back to INBOX rather than throwing: a server with no Drafts
        // folder should not make the app unusable, and a draft in the inbox is
        // recoverable in a way a crash is not.
        let name = match?.name ?? "INBOX"
        folderMap[kind] = name
        return name
    }

    func folder(for query: MailQuery) async throws -> String {
        switch query {
        case .folder(let mailbox):
            switch mailbox {
            case .inbox, .flagged: return "INBOX"
            case .sent:    return try await wellKnown(.sent)
            case .drafts:  return try await wellKnown(.drafts)
            case .trash:   return try await wellKnown(.trash)
            case .archive: return try await wellKnown(.archive)
            }
        case .and(let parts):
            for part in parts {
                if case .folder = part { return try await folder(for: part) }
            }
            return "INBOX"
        default:
            return "INBOX"
        }
    }

    @discardableResult
    func select(_ folder: String) async throws -> IMAPConnection.Selection {
        try await retrying { try await $0.select(folder) }
    }

    func search(_ criteria: String) async throws -> [Int] {
        try await retrying { try await $0.searchUIDs(criteria) }
    }

    func append(_ raw: String, to folder: String, flags: [String]) async throws {
        try await retrying { try await $0.append(Data(raw.utf8), to: folder, flags: flags) }
    }

    func delete(uid: Int, in folder: String) async throws {
        try await retrying {
            try await $0.select(folder)
            try await $0.delete(uid: uid)
        }
    }

    // MARK: - Fetching

    /// Whole messages, by UID.
    ///
    /// `BODY.PEEK[]` rather than `BODY[]`, and the difference matters: the
    /// second marks mail read as a side effect of looking at it. An app that
    /// syncs in the background would silently mark an entire inbox read.
    func fetch(uids: [Int], folder: String) async throws -> [Message] {
        guard !uids.isEmpty else { return [] }

        let set = Self.compress(uids)
        let lines = try await retrying {
            try await $0.fetch("\(set) (UID FLAGS BODY.PEEK[])")
        }

        return lines.compactMap { line in
            guard let uid = Self.value("UID", in: line.text),
                  let raw = line.literals.first
            else { return nil }

            return message(
                from: raw,
                uid: uid,
                flags: Self.flags(in: line.text),
                folder: folder
            )
        }
        .sorted { $0.date > $1.date }
    }

    /// One part of one message -- an attachment, fetched only when opened.
    func part(uid: Int, section: String) async throws -> Data {
        let lines = try await retrying {
            try await $0.fetch("\(uid) (BODY.PEEK[\(section)])")
        }
        guard let raw = lines.first?.literals.first else { return Data() }

        // The part arrives in whatever encoding it was posted in, and for an
        // attachment that is almost always base64.
        let text = String(decoding: raw, as: UTF8.self)
        if let decoded = Data(
            base64Encoded: text.components(separatedBy: .whitespacesAndNewlines).joined(),
            options: [.ignoreUnknownCharacters]
        ), !decoded.isEmpty {
            return decoded
        }
        return raw
    }

    /// A raw message into the app's shape.
    private func message(from raw: Data, uid: Int, flags: Set<String>, folder: String) -> Message {
        let parsed = MIMEParser.parse(raw)

        return Message(
            sender: parsed.from ?? Contact(name: "Unknown", address: ""),
            recipients: parsed.to + parsed.cc,
            subject: parsed.subject,
            body: parsed.text ?? "",
            date: parsed.date,
            isRead: flags.contains("\\SEEN"),
            isFlagged: flags.contains("\\FLAGGED"),
            mailbox: Self.mailbox(for: folder, flags: flags),
            remoteID: Self.reference(folder: folder, uid: uid),
            threadID: Self.thread(of: parsed),
            accountID: account.id,
            messageIDHeader: parsed.messageID,
            htmlBody: parsed.html,
            hasAttachment: !parsed.attachments.isEmpty,
            attachments: parsed.attachments.map {
                Attachment(
                    id: $0.section,
                    messageRemoteID: Self.reference(folder: folder, uid: uid),
                    filename: $0.filename,
                    mimeType: $0.mimeType,
                    size: $0.size
                )
            }
        )
    }

    /// Which conversation a message belongs to, without a provider to ask.
    ///
    /// Gmail hands over a `threadId`. IMAP has nothing, so the answer comes
    /// from `References`: every client appends the message it is replying to,
    /// so the *first* id in that chain is the message that started the thread
    /// and is the same for everybody in it.
    ///
    /// A message with no references started its own thread, and is its own id.
    static func thread(of parsed: MIMEParser.Parsed) -> String? {
        if let references = parsed.references,
           let root = references.split(separator: " ").first(where: { $0.hasPrefix("<") }) {
            return String(root)
        }
        return parsed.inReplyTo ?? parsed.messageID
    }

    private static func mailbox(for folder: String, flags: Set<String>) -> Mailbox {
        if flags.contains("\\DRAFT") { return .drafts }
        let leaf = folder.lowercased()
        if leaf.contains("sent") { return .sent }
        if leaf.contains("trash") || leaf.contains("deleted") || leaf.contains("bin") { return .trash }
        if leaf.contains("archive") || leaf.contains("all mail") { return .archive }
        return .inbox
    }

    // MARK: - Sending

    func send(_ envelope: MIMEBuilder.Envelope) async throws -> SentReceipt {
        guard let password = Keychain.read(.smtpPassword, for: account.id)
            ?? Keychain.read(.imapPassword, for: account.id)
        else {
            throw SMTPConnection.Failure.authRefused
        }

        let smtp = SMTPConnection(
            host: config.smtpHost,
            port: config.smtpPort,
            security: config.smtpSecurity
        )
        try await smtp.open()
        try await smtp.login(username: config.username, password: password)

        // 🔴 Bcc goes in the envelope, never in the message.
        //
        // `MIMEBuilder` writes a `Bcc:` header because a *draft* needs one to
        // remember who was on it. Delivering that header would show every
        // recipient the blind-copied list, which is the one thing Bcc exists
        // to prevent. So the header is stripped and the addresses are named to
        // the server instead, where they route the mail without appearing in
        // it.
        var forWire = envelope
        forWire.bcc = nil

        let recipients = Self.addresses(envelope.to)
            + Self.addresses(envelope.cc)
            + Self.addresses(envelope.bcc)

        try await smtp.deliver(
            raw: Data(MIMEBuilder.message(forWire).utf8),
            from: account.address,
            to: recipients
        )
        await smtp.close()

        return SentReceipt(id: envelope.inReplyTo ?? UUID().uuidString)
    }

    private static func addresses(_ list: String?) -> [String] {
        MIMEParser.addresses(list).map(\.address)
    }

    // MARK: - Response bits

    /// `UID 1234` out of a FETCH line.
    static func value(_ name: String, in line: String) -> Int? {
        guard let range = line.range(of: "\(name) ", options: .caseInsensitive) else { return nil }
        return Int(line[range.upperBound...].prefix(while: \.isNumber))
    }

    /// `FLAGS (\Seen \Answered)` out of a FETCH line.
    static func flags(in line: String) -> Set<String> {
        guard let start = line.range(of: "FLAGS (", options: .caseInsensitive),
              let end = line[start.upperBound...].firstIndex(of: ")")
        else { return [] }

        return Set(
            line[start.upperBound..<end]
                .split(separator: " ")
                .map { $0.uppercased() }
        )
    }

    /// `1,2,3,4,7` as `1:4,7`.
    ///
    /// A thousand-message import would otherwise send a command line with a
    /// thousand numbers in it, which some servers refuse outright and all of
    /// them handle badly.
    static func compress(_ uids: [Int]) -> String {
        let sorted = uids.sorted()
        guard !sorted.isEmpty else { return "" }

        var ranges: [String] = []
        var start = sorted[0]
        var previous = sorted[0]

        for uid in sorted.dropFirst() {
            if uid == previous + 1 { previous = uid; continue }
            ranges.append(start == previous ? "\(start)" : "\(start):\(previous)")
            start = uid
            previous = uid
        }
        ranges.append(start == previous ? "\(start)" : "\(start):\(previous)")
        return ranges.joined(separator: ",")
    }
}
