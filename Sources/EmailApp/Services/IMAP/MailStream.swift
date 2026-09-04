import Foundation

/// A socket that speaks a text line protocol, with TLS.
///
/// IMAP and SMTP are the last two things Maily needs that iOS does not ship.
/// There is no IMAP client in the SDK, no SMTP client, and nothing in
/// `URLSession` that helps -- both are conversations over a socket rather than
/// requests over HTTP. So this is the floor both of them stand on.
///
/// ## Why `Stream` and not `Network.framework`
///
/// `NWConnection` is the modern API and it was the first choice. It cannot do
/// STARTTLS: TLS is decided when the connection is created and there is no
/// supported way to upgrade one mid-conversation. STARTTLS is exactly that
/// upgrade, and it is what most submission servers still want on port 587.
///
/// `InputStream`/`OutputStream` can, through the CFStream security-level
/// property, which is the documented way this has always been done. Older API,
/// and the one that actually does the job.
///
/// ## Why a `DispatchQueue` and not an actor
///
/// 🔴 The reads here **block**. Blocking is fine on a GCD queue, which grows
/// its thread pool when a thread stops making progress. It is not fine on the
/// Swift concurrency pool, which has one thread per core and no more: block
/// those and everything stops, with no crash and no message. That is not
/// hypothetical -- it is the import hang, and the note in `Guarded` is about
/// the same mistake made a different way.
///
/// So every blocking call happens on `queue`, and `async` callers are bridged
/// with continuations. Nothing in this file may be made an `actor` without
/// making the I/O non-blocking first.
final class MailStream: @unchecked Sendable {

    /// What went wrong, in words somebody can act on.
    enum Failure: LocalizedError, Equatable {
        case cannotReach(String)
        case tlsFailed
        case timedOut
        case closed

        var errorDescription: String? {
            switch self {
            case .cannotReach(let host):
                "Could not reach \(host). Check the server address and that you are online."
            case .tlsFailed:
                "The secure connection was refused. Check the port and the encryption setting."
            case .timedOut:
                "The server stopped responding."
            case .closed:
                "The connection closed unexpectedly."
            }
        }
    }

    private let host: String
    private let port: Int
    private let queue: DispatchQueue

    private var input: InputStream?
    private var output: OutputStream?

    /// What has arrived and not yet been handed out. IMAP does not respect
    /// packet boundaries -- one read can bring half a line or nine of them --
    /// so everything goes here first and is taken out by line or by count.
    private var buffer = Data()

    /// How long any single read waits before the socket is pulled out from
    /// under it. There is no way to cancel a blocking read; closing the stream
    /// is what makes it return.
    private let timeout: TimeInterval

    init(host: String, port: Int, timeout: TimeInterval = 30) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.queue = DispatchQueue(label: "maily.mailstream.\(host)")
    }

    deinit { hardClose() }

    // MARK: - Opening

    /// Opens the socket, and negotiates TLS first if this is an implicit-TLS
    /// port (993 for IMAP, 465 for SMTP).
    func open(secure: Bool) async throws {
        try await onQueue {
            var input: InputStream?
            var output: OutputStream?
            Stream.getStreamsToHost(
                withName: self.host,
                port: self.port,
                inputStream: &input,
                outputStream: &output
            )

            guard let input, let output else {
                throw Failure.cannotReach(self.host)
            }
            self.input = input
            self.output = output

            // Before opening, so the handshake happens as part of connecting
            // rather than after something has already been sent in the clear.
            if secure { try self.applyTLS() }

            input.open()
            output.open()
            try self.waitUntilOpen()
        }
    }

    /// The STARTTLS upgrade: same socket, secured from here on.
    ///
    /// Only legal once the server has answered its half of the exchange -- for
    /// SMTP that is a 220 to `STARTTLS`, for IMAP an OK to `STARTTLS`. Called
    /// before that, it secures a stream the server is still speaking plainly
    /// on and the handshake fails.
    func upgradeToTLS() async throws {
        try await onQueue {
            try self.applyTLS()
            // The handshake happens on the next read or write. Nothing to wait
            // for here; a failure surfaces there as a closed stream.
        }
    }

    private func applyTLS() throws {
        guard let input, let output else { throw Failure.closed }

        let ok = input.setProperty(
            StreamSocketSecurityLevel.negotiatedSSL.rawValue,
            forKey: .socketSecurityLevelKey
        ) && output.setProperty(
            StreamSocketSecurityLevel.negotiatedSSL.rawValue,
            forKey: .socketSecurityLevelKey
        )

        guard ok else { throw Failure.tlsFailed }
    }

    /// Polls rather than scheduling on a run loop.
    ///
    /// A run loop would mean owning a thread and pumping it for the life of
    /// the connection. These streams are only ever read and written from this
    /// one queue, so asking their status directly is both simpler and the
    /// thing that keeps all the blocking in one place.
    private func waitUntilOpen() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let inStatus = input?.streamStatus ?? .error
            let outStatus = output?.streamStatus ?? .error

            if inStatus == .error || outStatus == .error {
                throw input?.streamError ?? Failure.cannotReach(host)
            }
            if inStatus == .open && outStatus == .open { return }

            Thread.sleep(forTimeInterval: 0.02)
        }
        throw Failure.timedOut
    }

    // MARK: - Talking

    /// Writes a line, terminated the way both protocols require.
    ///
    /// ⚠️ Never log the argument. `LOGIN` and `AUTH` lines go through here
    /// with the password in them.
    func send(_ line: String) async throws {
        try await onQueue {
            try self.write(Data((line + "\r\n").utf8))
        }
    }

    /// Writes raw bytes, for an IMAP literal or an SMTP `DATA` body.
    func send(_ data: Data) async throws {
        try await onQueue { try self.write(data) }
    }

    private func write(_ data: Data) throws {
        guard let output else { throw Failure.closed }
        var remaining = data

        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base, maxLength: remaining.count)
            }
            guard written > 0 else { throw output.streamError ?? Failure.closed }
            remaining.removeFirst(written)
        }
    }

    /// The next line, without its CRLF.
    func line() async throws -> String {
        try await onQueue { try self.readLine() }
    }

    private func readLine() throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                // Not every header is UTF-8; a lone Latin-1 byte in a subject
                // should not take down the connection carrying it.
                return String(decoding: line, as: UTF8.self)
            }
            try fill()
        }
    }

    /// Exactly this many bytes, for an IMAP literal.
    ///
    /// A literal is announced as `{1234}` and the bytes that follow are not a
    /// line -- they can contain CRLF, and usually do. Counting is the only way
    /// to know where the message stops and the response resumes.
    func bytes(_ count: Int) async throws -> Data {
        try await onQueue {
            while self.buffer.count < count {
                try self.fill()
            }
            let taken = self.buffer.prefix(count)
            self.buffer.removeFirst(count)
            return Data(taken)
        }
    }

    /// One blocking read, with the socket closed under it if it never returns.
    private func fill() throws {
        guard let input else { throw Failure.closed }

        // There is no timeout on `read`. Closing the stream is what unblocks
        // it, so a watchdog on another queue does exactly that. It is armed
        // per read and cancelled the moment bytes arrive.
        let watchdog = DispatchWorkItem { [weak self] in self?.hardClose() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        var chunk = [UInt8](repeating: 0, count: 8192)
        let read = input.read(&chunk, maxLength: chunk.count)

        if read > 0 {
            buffer.append(contentsOf: chunk[0..<read])
            return
        }
        // Zero is a clean close, negative is an error. Neither can be waited
        // out, and both mean this connection is finished.
        if read == 0 { throw Failure.closed }
        throw input.streamError ?? Failure.timedOut
    }

    // MARK: - Closing

    func close() async {
        try? await onQueue { self.hardClose() }
    }

    /// Also called from the watchdog and from `deinit`, so it has to be safe
    /// off the queue and safe twice.
    private func hardClose() {
        input?.close()
        output?.close()
        input = nil
        output = nil
    }

    // MARK: - The bridge

    /// Runs blocking work on the queue and hands the result back to `async`.
    ///
    /// The one place the two worlds meet. Everything above is written as if it
    /// were synchronous because on `queue` it is.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
