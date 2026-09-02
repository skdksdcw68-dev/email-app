import XCTest
@testable import EmailApp

/// Typed memories with an end date, and the fence the model uses to set one.
@MainActor
final class MemoryTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "memory-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: offset, to: .now)!)
    }

    // MARK: - The prompt

    func testThePromptGroupsByKindUnderHeadings() {
        let memory = AIMemory(fileURL: fileURL)
        memory.remember("Keep replies to three lines", kind: .preference)
        memory.remember("Yohannes is my accountant", kind: .person)
        memory.remember("I'm a freelance designer", kind: .aboutMe)

        let prompt = memory.prompt

        XCTAssertTrue(prompt.contains("How they like things done:\n- Keep replies to three lines"), prompt)
        XCTAssertTrue(prompt.contains("About them:\n- I'm a freelance designer"), prompt)
        XCTAssertTrue(prompt.contains("People in their life:\n- Yohannes is my accountant"), prompt)
        XCTAssertFalse(prompt.contains("Their situation at the moment:"))
    }

    func testASituationCarriesItsEndDate() {
        let memory = AIMemory(fileURL: fileURL)
        memory.remember("Travelling", kind: .situation, until: day(10))

        XCTAssertTrue(memory.prompt.contains("- Travelling (until "), memory.prompt)
    }

    func testAnExpiredSituationIsKeptButNotSent() {
        let memory = AIMemory(fileURL: fileURL)
        memory.remember("Travelling", kind: .situation, until: day(-1))
        memory.remember("Keep it short", kind: .preference)

        XCTAssertEqual(memory.facts.count, 2)
        XCTAssertTrue(memory.facts.first { $0.text == "Travelling" }!.isExpired())
        XCTAssertFalse(memory.prompt.contains("Travelling"), memory.prompt)
        XCTAssertTrue(memory.prompt.contains("Keep it short"))
    }

    func testASituationEndingTodayStillApplies() {
        let memory = AIMemory(fileURL: fileURL)
        memory.remember("Out of office", kind: .situation, until: day(0))
        XCTAssertTrue(memory.prompt.contains("Out of office"))
    }

    func testNothingLiveMeansAnEmptyPrompt() {
        let memory = AIMemory(fileURL: fileURL)
        memory.remember("Over", kind: .situation, until: day(-3))
        XCTAssertEqual(memory.prompt, "")
    }

    func testTheSameSentenceIsNotKeptTwice() {
        let memory = AIMemory(fileURL: fileURL)
        XCTAssertNotNil(memory.remember("I sign off as Abel"))
        XCTAssertNil(memory.remember("i sign off as abel"))
        XCTAssertEqual(memory.facts.count, 1)
    }

    // MARK: - Disk

    func testKindAndEndDateSurviveARelaunch() {
        let memory = AIMemory(fileURL: fileURL)
        memory.remember("Travelling", kind: .situation, until: day(5))

        let reloaded = AIMemory(fileURL: fileURL)
        XCTAssertEqual(reloaded.facts.first?.kind, .situation)
        XCTAssertEqual(reloaded.facts.first?.until, day(5))
    }

    func testAFileWrittenBeforeKindsDecodesAsPreferences() throws {
        // What every memory was, before there was a choice.
        let old = """
        [{"id":"7B1D2E3A-0000-4000-8000-000000000001","text":"Keep it short","createdAt":0}]
        """
        try Data(old.utf8).write(to: fileURL)

        let memory = AIMemory(fileURL: fileURL)
        XCTAssertEqual(memory.facts.count, 1)
        XCTAssertEqual(memory.facts.first?.kind, .preference)
        XCTAssertNil(memory.facts.first?.until)
    }

    // MARK: - The fence

    func testARememberFenceBecomesANote() {
        let answer = AnswerFences.read(from: """
        Got it.

        ```remember
        kind: situation
        until: 2026-09-12
        text: Travelling until the 12th.
        ```

        I'll keep that in mind.
        """)

        XCTAssertEqual(answer.prose, "Got it.\n\nI'll keep that in mind.")
        XCTAssertEqual(answer.memories.count, 1)
        XCTAssertEqual(answer.memories[0].kind, .situation)
        XCTAssertEqual(answer.memories[0].text, "Travelling until the 12th.")
        XCTAssertEqual(answer.memories[0].until, Extraction.day("2026-09-12"))
        XCTAssertTrue(answer.blocks.isEmpty)
    }

    func testAFenceWithoutAnEndDateOrKindIsAPreference() {
        let answer = AnswerFences.read(from: "```remember\ntext: I sign off as Abel\nuntil: none\n```")
        XCTAssertEqual(answer.memories, [MemoryNote(kind: .preference, text: "I sign off as Abel")])
    }

    func testAKindTheAppDoesNotKnowFallsBackToPreference() {
        let answer = AnswerFences.read(from: "```remember\nkind: mood\ntext: Cheerful today\n```")
        XCTAssertEqual(answer.memories.first?.kind, .preference)
    }

    func testAboutMeIsReadWithEitherSpelling() {
        XCTAssertEqual(MemoryNote(fence: "kind: about_me\ntext: I'm a designer")?.kind, .aboutMe)
        XCTAssertEqual(MemoryNote(fence: "kind: About me\ntext: I'm a designer")?.kind, .aboutMe)
    }

    func testAFenceWithNoTextIsNothing() {
        let answer = AnswerFences.read(from: "```remember\nkind: person\n```")
        XCTAssertTrue(answer.memories.isEmpty)
        XCTAssertEqual(answer.prose, "")
    }

    func testAHalfStreamedRememberFenceIsHeldBack() {
        let answer = AnswerFences.read(from: "Sure.\n\n```remember\nkind: person\ntext: Yoh")
        XCTAssertEqual(answer.prose, "Sure.")
        XCTAssertTrue(answer.memories.isEmpty)
    }

    func testTheTupleFormStillWorksForTheOtherFences() {
        let (prose, blocks) = AnswerFences.extract(from: "Here.\n\n```stats\nUrgent: 3\n```")
        XCTAssertEqual(prose, "Here.")
        XCTAssertEqual(blocks.count, 1)
    }
}
