import XCTest
@testable import EmailApp

/// Gmail describes attachments in the same part tree as the body, and the
/// difference between a file somebody wants and a tracking pixel is one
/// header. Getting it wrong offers junk to open, or hides the invoice.
final class AttachmentTests: XCTestCase {

    private func part(
        filename: String,
        mimeType: String,
        attachmentID: String?,
        size: Int = 0,
        disposition: String? = nil,
        parts: [[String: Any]] = []
    ) -> [String: Any] {
        var body: [String: Any] = ["size": size]
        if let attachmentID { body["attachmentId"] = attachmentID }

        var result: [String: Any] = [
            "filename": filename,
            "mimeType": mimeType,
            "body": body,
        ]
        if let disposition {
            result["headers"] = [["name": "Content-Disposition", "value": disposition]]
        }
        if !parts.isEmpty { result["parts"] = parts }
        return result
    }

    func testFindsAnAttachmentInAMultipartTree() {
        let payload = part(filename: "", mimeType: "multipart/mixed", attachmentID: nil, parts: [
            part(filename: "", mimeType: "text/plain", attachmentID: nil),
            part(filename: "invoice.pdf", mimeType: "application/pdf",
                 attachmentID: "att-1", size: 1024),
        ])

        let found = GmailService.attachments(in: payload, messageID: "msg-1")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].filename, "invoice.pdf")
        XCTAssertEqual(found[0].id, "att-1")
        XCTAssertEqual(found[0].messageRemoteID, "msg-1")
        XCTAssertEqual(found[0].size, 1024)
        XCTAssertEqual(found[0].mimeType, "application/pdf")
    }

    func testAnInlineImageIsNotOfferedAsAFile() {
        // A logo the HTML body draws is not something anybody wants a row for.
        let payload = part(filename: "", mimeType: "multipart/related", attachmentID: nil, parts: [
            part(filename: "logo.png", mimeType: "image/png", attachmentID: "att-inline",
                 disposition: "inline; filename=\"logo.png\""),
        ])
        XCTAssertTrue(GmailService.attachments(in: payload, messageID: "msg-1").isEmpty)
    }

    func testAnAttachedImageIsStillAnAttachment() {
        let payload = part(filename: "", mimeType: "multipart/mixed", attachmentID: nil, parts: [
            part(filename: "photo.jpg", mimeType: "image/jpeg", attachmentID: "att-2",
                 disposition: "attachment; filename=\"photo.jpg\""),
        ])
        XCTAssertEqual(GmailService.attachments(in: payload, messageID: "msg-1").count, 1)
    }

    func testAPartWithNoAttachmentIdIsSkipped() {
        // Without an id there is nothing to fetch, so a row for it would be a
        // button that cannot work.
        let payload = part(filename: "inline.txt", mimeType: "text/plain", attachmentID: nil)
        XCTAssertTrue(GmailService.attachments(in: payload, messageID: "msg-1").isEmpty)
    }

    func testNestedPartsAreReached() {
        let payload = part(filename: "", mimeType: "multipart/mixed", attachmentID: nil, parts: [
            part(filename: "", mimeType: "multipart/alternative", attachmentID: nil, parts: [
                part(filename: "", mimeType: "text/plain", attachmentID: nil),
                part(filename: "deck.pptx", mimeType: "application/vnd.ms-powerpoint",
                     attachmentID: "att-3"),
            ]),
            part(filename: "notes.txt", mimeType: "text/plain", attachmentID: "att-4"),
        ])

        let names = GmailService.attachments(in: payload, messageID: "m").map(\.filename)
        XCTAssertEqual(Set(names), ["deck.pptx", "notes.txt"])
    }

    // MARK: - How one is described

    func testSizeIsHumanReadableAndSilentWhenUnknown() {
        let known = Attachment(id: "a", messageRemoteID: "m", filename: "f.pdf",
                               mimeType: "application/pdf", size: 1_500_000)
        XCTAssertFalse(known.sizeDescription.isEmpty)

        // "Zero bytes" reads as a broken file, so an unknown size says nothing.
        let unknown = Attachment(id: "a", messageRemoteID: "m", filename: "f.pdf",
                                 mimeType: "application/pdf", size: 0)
        XCTAssertTrue(unknown.sizeDescription.isEmpty)
    }

    func testTheSymbolFollowsTheKindOfFile() {
        func symbol(_ name: String, _ type: String) -> String {
            Attachment(id: "a", messageRemoteID: "m", filename: name, mimeType: type, size: 1).symbol
        }
        XCTAssertEqual(symbol("invoice.pdf", "application/pdf"), "doc.richtext")
        XCTAssertEqual(symbol("photo.jpg", "image/jpeg"), "photo")
        XCTAssertEqual(symbol("clip.mp4", "video/mp4"), "film")
        // Unknown is generic rather than wrong.
        XCTAssertEqual(symbol("thing.qqq", "application/x-made-up"), "paperclip")
    }
}
