import XCTest
@testable import EmailApp

/// The send path is the one place a mistake cannot be taken back: a malformed
/// message goes out malformed. So the structure is checked rather than
/// assumed.
@MainActor
final class MIMEAttachmentTests: XCTestCase {

    private func file(
        _ name: String = "invoice.pdf",
        type: String = "application/pdf",
        bytes: String = "hello"
    ) -> MIMEBuilder.Attached {
        MIMEBuilder.Attached(filename: name, mimeType: type, data: Data(bytes.utf8))
    }

    private func envelope(
        html: String? = nil,
        attachments: [MIMEBuilder.Attached] = []
    ) -> MIMEBuilder.Envelope {
        MIMEBuilder.Envelope(
            from: "Abel <abel@example.com>",
            to: "sara@example.com",
            cc: nil,
            subject: "Hello",
            plainText: "Hi there",
            html: html,
            inReplyTo: nil,
            references: nil,
            attachments: attachments
        )
    }

    // MARK: - Nothing attached behaves exactly as before

    func testNoAttachmentsProducesASinglePartMessage() {
        let message = MIMEBuilder.message(envelope(), boundary: "OUTER")
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=\"UTF-8\""), message)
        XCTAssertFalse(message.contains("multipart/mixed"))
        XCTAssertFalse(message.contains("OUTER"))
    }

    func testNoAttachmentsWithHTMLIsStillAPlainAlternative() {
        let message = MIMEBuilder.message(envelope(html: "<p>Hi</p>"), boundary: "OUTER")
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary=\"OUTER\""))
        XCTAssertFalse(message.contains("multipart/mixed"))
    }

    // MARK: - With attachments

    func testAttachmentsWrapTheMessageInMultipartMixed() {
        let message = MIMEBuilder.message(
            envelope(attachments: [file()]), boundary: "OUTER"
        )
        XCTAssertTrue(message.contains("Content-Type: multipart/mixed; boundary=\"OUTER\""), message)
        XCTAssertTrue(message.contains("--OUTER"))
        // The closing delimiter takes a trailing "--", or the last part is
        // unterminated and clients drop it.
        XCTAssertTrue(message.hasSuffix("--OUTER--"), String(message.suffix(40)))
    }

    func testTheAttachmentCarriesItsNameTypeAndDisposition() {
        let message = MIMEBuilder.message(
            envelope(attachments: [file("report.pdf")]), boundary: "OUTER"
        )
        XCTAssertTrue(message.contains("Content-Type: application/pdf; name=\"report.pdf\""), message)
        XCTAssertTrue(
            message.contains("Content-Disposition: attachment; filename=\"report.pdf\""), message
        )
        XCTAssertTrue(message.contains("Content-Transfer-Encoding: base64"))
        // "hello" in base64.
        XCTAssertTrue(message.contains("aGVsbG8="), message)
    }

    func testHTMLAndAttachmentsNestAnAlternativeInsideTheMixed() {
        // The text pair has to be its own part with its own boundary. Reusing
        // the parent's would end the outer part at the first inner delimiter,
        // and the attachment would vanish.
        let message = MIMEBuilder.message(
            envelope(html: "<p>Hi</p>", attachments: [file()]),
            boundary: "OUTER",
            alternativeBoundary: "INNER"
        )
        XCTAssertTrue(message.contains("Content-Type: multipart/mixed; boundary=\"OUTER\""))
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary=\"INNER\""))
        XCTAssertTrue(message.contains("--INNER--"))
        XCTAssertTrue(message.hasSuffix("--OUTER--"))

        // The inner section must close before the first attachment starts.
        guard let innerClose = message.range(of: "--INNER--"),
              let attachmentStart = message.range(of: "Content-Disposition: attachment")
        else { return XCTFail("expected both") }
        XCTAssertLessThan(innerClose.upperBound, attachmentStart.lowerBound)
    }

    func testSeveralAttachmentsEachGetTheirOwnPart() {
        let message = MIMEBuilder.message(
            envelope(attachments: [file("one.pdf"), file("two.txt", type: "text/plain")]),
            boundary: "OUTER"
        )
        XCTAssertTrue(message.contains("filename=\"one.pdf\""))
        XCTAssertTrue(message.contains("filename=\"two.txt\""))
        XCTAssertEqual(
            message.components(separatedBy: "Content-Disposition: attachment").count - 1, 2
        )
    }

    func testAMissingMimeTypeFallsBackRatherThanEmittingAnEmptyOne() {
        let message = MIMEBuilder.message(
            envelope(attachments: [file("thing", type: "")]), boundary: "OUTER"
        )
        XCTAssertTrue(message.contains("Content-Type: application/octet-stream; name=\"thing\""), message)
    }

    // MARK: - Filenames off the wire

    func testAQuoteInAFilenameCannotEndTheHeaderEarly() {
        // Otherwise everything after the quote is read as more parameters.
        let name = MIMEBuilder.encodedFilename("in\"voice.pdf")
        XCTAssertFalse(name.contains("\""))
        XCTAssertEqual(name, "invoice.pdf")
    }

    func testANewlineInAFilenameCannotInjectAHeader() {
        let name = MIMEBuilder.encodedFilename("a.pdf\r\nBcc: attacker@example.com")
        XCTAssertFalse(name.contains("\r"))
        XCTAssertFalse(name.contains("\n"))
    }

    func testANonASCIIFilenameIsEncoded() {
        let name = MIMEBuilder.encodedFilename("rapport-café.pdf")
        XCTAssertTrue(name.hasPrefix("=?UTF-8?B?"), name)
        XCTAssertTrue(name.hasSuffix("?="))
    }

    func testAnEmptyFilenameStillNamesSomething() {
        XCTAssertEqual(MIMEBuilder.encodedFilename("   "), "attachment")
    }

    // MARK: - The size ceiling

    func testTheLimitIsRefusedBeforeAnythingIsUploaded() async {
        let store = MailStore.connected()
        let huge = MIMEBuilder.Attached(
            filename: "big.bin",
            mimeType: "application/octet-stream",
            data: Data(count: MIMEBuilder.attachmentLimit + 1)
        )

        do {
            try await store.send(subject: "Hi", to: "a@b.com", body: "there", attachments: [huge])
            XCTFail("Sending over the limit should throw before uploading")
        } catch let error as MailStore.SendError {
            guard case .attachmentsTooLarge = error else {
                return XCTFail("Expected the size error, got \(error)")
            }
            // The message has to carry the number, or somebody removes files
            // at random trying to get under it.
            XCTAssertTrue(error.errorDescription?.contains("MB") ?? false, error.errorDescription ?? "")
        } catch {
            XCTFail("Expected a SendError, got \(error)")
        }
    }
}
