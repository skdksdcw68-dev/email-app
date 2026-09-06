import XCTest
@testable import EmailApp

final class PeopleDirectoryTests: XCTestCase {

    // MARK: - Asking Google for a picture worth drawing

    func testThumbnailSuffixIsRaised() {
        // Google hands out =s100. In a 44pt circle on a 3x screen that is a
        // soft picture; the suffix is a request and the same URL answers 256.
        let url = PeopleDirectory.sharpened("https://lh3.googleusercontent.com/a-/ALV-abc=s100")
        XCTAssertEqual(url?.absoluteString, "https://lh3.googleusercontent.com/a-/ALV-abc=s256-c")
    }

    func testCroppedSuffixIsReplacedNotAppended() {
        let url = PeopleDirectory.sharpened("https://lh3.googleusercontent.com/a/ACg8oc=s100-c")
        XCTAssertEqual(url?.absoluteString, "https://lh3.googleusercontent.com/a/ACg8oc=s256-c")
    }

    func testURLWithoutASizeIsLeftAlone() {
        let url = PeopleDirectory.sharpened("https://example.com/photo.jpg")
        XCTAssertEqual(url?.absoluteString, "https://example.com/photo.jpg")
    }

    func testEmptyIsNil() {
        XCTAssertNil(PeopleDirectory.sharpened(""))
    }
}
