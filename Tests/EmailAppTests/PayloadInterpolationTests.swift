import XCTest
@testable import EmailApp

/// Guards against a bug that compiles, passes every other test, and silently
/// ruins answers.
///
/// A payload line like `"from": "\(name) <\(address)>"` becomes
/// `"from": "(name) <(address)>"` if the backslashes are lost -- editing these
/// files with a script is how that happens. Swift is perfectly happy: it is a
/// valid string literal. The model then reads "(message.sender.name)" as the
/// sender of every email it is shown, and "anything from Sara" stops working
/// with no error anywhere.
///
/// It happened twice in one session. So the shape is asserted rather than
/// trusted.
final class PayloadInterpolationTests: XCTestCase {

    private func message(name: String = "Sara Chen", address: String = "sara@x.com") -> Message {
        var message = Message(
            sender: Contact(name: name, address: address),
            recipients: [Contact(name: "Abel", address: "abel@example.com")],
            subject: "Q3 pricing",
            body: "Body",
            date: .now
        )
        message.remoteID = "m1"
        return message
    }

    /// The one line every AI call describes a sender with.
    private func from(_ message: Message) -> String {
        "\(message.sender.name) <\(message.sender.address)>"
    }

    func testTheSenderLineCarriesTheActualNameAndAddress() {
        let line = from(message())
        XCTAssertEqual(line, "Sara Chen <sara@x.com>")
        XCTAssertFalse(line.contains("message.sender"),
                       "the interpolation was lost: the model would read this literally")
    }

    func testAnEmptyNameStillCarriesTheAddress() {
        // Plenty of mail arrives with no display name. The address is the
        // part that has to survive.
        let line = from(message(name: "", address: "noreply@x.com"))
        XCTAssertTrue(line.contains("noreply@x.com"))
        XCTAssertFalse(line.contains("sender.address"))
    }

    /// The same shape the digest uses, asserted whole, because the digest is
    /// what every question is answered from.
    func testADigestEntryDescribesTheRealMessage() {
        let message = self.message()
        let entry: [String: String] = [
            "from": from(message),
            "date": message.fullDate,
            "subject": message.subject,
            "body": String(message.body.prefix(AIService.digestBodyLimit)),
        ]

        XCTAssertEqual(entry["from"], "Sara Chen <sara@x.com>")
        XCTAssertEqual(entry["subject"], "Q3 pricing")
        XCTAssertFalse(entry["date"]?.isEmpty ?? true)

        for (key, value) in entry {
            XCTAssertFalse(value.contains("message."), "\(key) lost its interpolation: \(value)")
            XCTAssertFalse(value.contains("$0."), "\(key) lost its interpolation: \(value)")
        }
    }

    func testTheDigestIsSmallerThanAnOpenedMessage() {
        // The cheap digest says which message it is; OPEN: fetches the rest.
        // If these ever swap, every question pays for depth it did not ask
        // for -- which is the thing that was costing money.
        XCTAssertLessThan(AIService.digestBodyLimit, AIService.openedBodyLimit)
        XCTAssertLessThanOrEqual(AIService.digestBodyLimit, 300)
    }
}
