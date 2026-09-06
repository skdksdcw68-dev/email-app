import SwiftUI
import XCTest
@testable import EmailApp

final class SenderAvatarTests: XCTestCase {

    // MARK: - The colour follows the letter, as in Gmail

    func testSameLetterIsSameColourWhateverTheAddress() {
        // Google mails from four hosts. Under the address hash that was four
        // colours in one screen; under Gmail's rule it is one.
        let alert = Contact(name: "Google", address: "no-reply@accounts.google.com")
        let play = Contact(name: "Google Play", address: "googleplay-noreply@google.com")
        XCTAssertEqual(SenderAvatar.color(for: alert), SenderAvatar.color(for: play))
    }

    func testCaseDoesNotChangeTheColour() {
        let upper = Contact(name: "Bitget", address: "noreply@bitget.com")
        let lower = Contact(name: "bybit", address: "noreply@bybit.com")
        XCTAssertEqual(SenderAvatar.color(for: upper), SenderAvatar.color(for: lower))
    }

    func testDifferentLettersDiffer() {
        let g = Contact(name: "Google", address: "x@google.com")
        let b = Contact(name: "Binance", address: "x@binance.com")
        XCTAssertNotEqual(SenderAvatar.color(for: g), SenderAvatar.color(for: b))
    }

    // MARK: - Which letter

    func testLetterComesFromTheName() {
        XCTAssertEqual(SenderAvatar.letter(for: Contact(name: "Google Play", address: "x@google.com")), "G")
    }

    func testLetterIsUppercased() {
        XCTAssertEqual(SenderAvatar.letter(for: Contact(name: "abel amare", address: "abel@gmail.com")), "A")
    }

    func testNameThatIsAnAddressUsesTheAddress() {
        let contact = Contact(name: "abel@gmail.com", address: "abel@gmail.com")
        XCTAssertEqual(SenderAvatar.letter(for: contact), "A")
    }

    func testLeadingPunctuationIsSkipped() {
        XCTAssertEqual(SenderAvatar.letter(for: Contact(name: "'Abel' Amare", address: "abel@gmail.com")), "A")
    }

    func testNothingToDrawIsAQuestionMark() {
        XCTAssertEqual(SenderAvatar.letter(for: Contact(name: "", address: "")), "?")
    }
}
