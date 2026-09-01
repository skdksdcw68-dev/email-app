import Foundation
import UniformTypeIdentifiers

/// A file that came with an email.
///
/// Gmail does not send the bytes with the message: a part carries a filename,
/// a size and an `attachmentId`, and the contents are a second request made
/// only if somebody actually opens it. A mailbox full of ten megabyte decks
/// would otherwise cost ten megabytes each to list.
struct Attachment: Identifiable, Hashable, Codable {
    /// Gmail's own id for the part. Unique within its message, which is why
    /// `messageRemoteID` travels with it.
    let id: String
    let messageRemoteID: String
    let filename: String
    let mimeType: String
    /// Bytes, as Gmail reported them. Zero when it did not say.
    let size: Int

    var type: UTType {
        UTType(mimeType: mimeType)
            ?? UTType(filenameExtension: (filename as NSString).pathExtension)
            ?? .data
    }

    /// The SF Symbol for this kind of file. Specific where it helps somebody
    /// find the right one at a glance, generic rather than wrong otherwise.
    var symbol: String {
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .spreadsheet) || filename.hasSuffix(".xlsx") || filename.hasSuffix(".csv") {
            return "tablecells"
        }
        if type.conforms(to: .presentation) || filename.hasSuffix(".pptx") { return "rectangle.on.rectangle" }
        if type.conforms(to: .archive) || type.conforms(to: .zip) { return "doc.zipper" }
        if type.conforms(to: .text) || filename.hasSuffix(".docx") { return "doc.text" }
        return "paperclip"
    }

    /// "1.2 MB". Empty when Gmail did not report a size, rather than "Zero
    /// bytes", which reads as a broken file.
    var sizeDescription: String {
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
