import XCTest
@testable import EmailApp

final class LogoDirectoryTests: XCTestCase {

    // MARK: - A miss is an answer, an absence is not

    /// The whole of the build-189 bug in one shape: a domain the server said
    /// "no logo" about must be remembered as such, and a domain the server
    /// did not mention must *not* be -- it is still being resolved.
    func testMissIsPresentWithNoURLAndUnfinishedIsAbsent() throws {
        let data = Data(#"""
        {"tiktok.com": {"url": "https://x/y.png", "source": "bimi"},
         "nothing.com": {"url": null, "source": "none"}}
        """#.utf8)

        let answers = try XCTUnwrap(LogoDirectory.parse(data))

        XCTAssertEqual(answers["tiktok.com"] ?? nil, URL(string: "https://x/y.png"))

        XCTAssertTrue(answers.keys.contains("nothing.com"))
        let miss = try XCTUnwrap(answers["nothing.com"])
        XCTAssertNil(miss)

        XCTAssertFalse(answers.keys.contains("slow.com"))
    }

    func testABodyThatIsNotJSONIsNoAnswerAtAll() {
        // A gateway error page, a timeout body -- nothing here may be
        // mistaken for "these companies have no logo".
        XCTAssertNil(LogoDirectory.parse(Data("<html>502</html>".utf8)))
    }

    func testAnEmptyObjectIsAnAnswerWithNothingInIt() throws {
        let answers = try XCTUnwrap(LogoDirectory.parse(Data("{}".utf8)))
        XCTAssertTrue(answers.isEmpty)
    }
}
