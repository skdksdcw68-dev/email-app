import Foundation

/// Downloads an attachment and puts it somewhere the system can open it.
///
/// Files land in a folder under Caches, named by Gmail's own attachment id,
/// so opening the same file twice costs one download. Caches is the right
/// home: the system may reclaim it under pressure, and the file is always a
/// request away again.
///
/// Nothing here is speculative. An attachment is fetched because somebody
/// tapped it, never because a message was listed.
@MainActor
@Observable
final class AttachmentStore {

    /// Attachments being fetched right now, so a row can show its own
    /// spinner rather than the screen showing one.
    private(set) var inFlight: Set<String> = []
    /// The last thing that went wrong, for the attachment it went wrong on.
    private(set) var failures: [String: String] = [:]

    private let directory: URL
    nonisolated(unsafe) private var disconnectObserver: NSObjectProtocol?

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory

        // Downloaded files are mail content like any other, so they go with
        // the mailbox.
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .mailboxDisconnected, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clear() }
        }
    }

    deinit {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    private static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    /// Where this attachment lives once it has been fetched.
    ///
    /// The id is in the directory name rather than the filename, so two
    /// messages that both attach "invoice.pdf" do not collide, and the file
    /// keeps its real name for the share sheet and for whatever opens it.
    func location(of attachment: Attachment) -> URL {
        directory
            .appending(path: fingerprint(attachment), directoryHint: .isDirectory)
            .appending(path: safeName(attachment.filename))
    }

    func isDownloaded(_ attachment: Attachment) -> Bool {
        FileManager.default.fileExists(atPath: location(of: attachment).path)
    }

    func isWorking(on attachment: Attachment) -> Bool {
        inFlight.contains(attachment.id)
    }

    func failure(for attachment: Attachment) -> String? {
        failures[attachment.id]
    }

    /// Fetches it if it is not already here, and hands back the file. Nil
    /// means it failed, and `failure(for:)` says why.
    func file(for attachment: Attachment) async -> URL? {
        let destination = location(of: attachment)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard !inFlight.contains(attachment.id) else { return nil }
        inFlight.insert(attachment.id)
        failures[attachment.id] = nil
        defer { inFlight.remove(attachment.id) }

        do {
            let token = try await AuthService.currentGmailAccessToken()
            let data = try await GmailService.attachmentData(
                messageID: attachment.messageRemoteID,
                attachmentID: attachment.id,
                accessToken: token
            )

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Not `.completeFileProtection`: the file has to stay readable by
            // QuickLook and by whatever the share sheet hands it to, which can
            // be running while the device is locked.
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            failures[attachment.id] = error.localizedDescription
            return nil
        }
    }

    /// Everything downloaded so far, gone. Called when the mailbox is
    /// disconnected: these are mail content like any other.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        failures = [:]
    }

    // MARK: - Naming

    /// Gmail's ids are long base64url strings, well past what a path
    /// component should carry, so the folder is a stable hash of it.
    private func fingerprint(_ attachment: Attachment) -> String {
        var hasher = Hasher()
        hasher.combine(attachment.messageRemoteID)
        hasher.combine(attachment.id)
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }

    /// A filename from an email is attacker-controlled. Path separators and
    /// leading dots come out, and something is always left.
    private func safeName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "." }
        let name = String(cleaned.prefix(120))
        return name.isEmpty ? "attachment" : name
    }
}
