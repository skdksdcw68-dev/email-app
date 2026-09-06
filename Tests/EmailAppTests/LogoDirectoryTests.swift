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

    // MARK: - The cache key follows the picture

    func testABetterAnswerIsANewKey() throws {
        // TikTok went from a favicon to its BIMI mark on the server and the
        // phone kept drawing the favicon: same domain, same key, fresh file.
        let favicon = try XCTUnwrap(URL(string: "https://www.google.com/s2/favicons?domain=tiktok.com"))
        let bimi = try XCTUnwrap(URL(string: "https://example.supabase.co/functions/v1/logos/img/tiktok.com"))

        let before = LogoDirectory.key(for: "tiktok.com", url: favicon)
        let after = LogoDirectory.key(for: "tiktok.com", url: bimi)

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before, LogoDirectory.key(for: "tiktok.com", url: favicon))
        XCTAssertTrue(before.hasPrefix("brand-tiktok.com-"))
    }
}
