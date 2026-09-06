import XCTest
@testable import EmailApp

/// The person's categories: the ten seeded, the ones they add, and what
/// the model is told.
@MainActor
final class CategoryStoreTests: XCTestCase {

    private var store: CategoryStore { .shared }

    override func setUp() {
        super.setUp()
        store.forgetAll()
    }

    override func tearDown() {
        store.forgetAll()
        super.tearDown()
    }

    private func support() -> Category {
        .custom(name: "Support requests", symbol: "lifepreserver.fill", color: .teal,
                guidance: "customers writing about a problem with an order")
    }

    func testTheTenAreSeeded() {
        XCTAssertEqual(store.all.count, AITag.allCases.count)
        XCTAssertEqual(store.category(for: .urgent).name, "Very Urgent")
        XCTAssertTrue(store.custom.isEmpty)
    }

    func testABuiltInCannotBeDeletedOnlyHidden() {
        store.remove(id: AITag.newsletter.rawValue)
        XCTAssertNotNil(store.category(id: AITag.newsletter.rawValue))

        store.setVisible(AITag.newsletter.rawValue, false)
        XCTAssertFalse(store.visible.contains { $0.id == AITag.newsletter.rawValue })
        XCTAssertEqual(store.visible.count, AITag.allCases.count - 1)
    }

    func testACustomCategoryIsWhatTheModelIsTold() {
        let category = support()
        store.add(category)

        XCTAssertEqual(store.customForModel.map(\.id), [category.id])
        XCTAssertEqual(store.customForModel.first?.what, "customers writing about a problem with an order")
        // Nothing about the built-ins, which the server already knows.
        XCTAssertTrue(store.notesForModel.isEmpty)
    }

    func testANoteOnABuiltInIsToldToo() {
        var important = store.category(for: .important)
        important.guidance = "newsletters from my bank are Important"
        store.update(important)

        XCTAssertEqual(store.notesForModel.map(\.id), [AITag.important.rawValue])
    }

    func testRewordingMovesTheRevisionAndRecolouringDoesNot() throws {
        let category = support()
        store.add(category)
        let before = try XCTUnwrap(store.category(id: category.id)).revision

        var recoloured = try XCTUnwrap(store.category(id: category.id))
        recoloured.color = .pink
        store.update(recoloured)
        XCTAssertEqual(store.category(id: category.id)?.revision, before)

        var reworded = try XCTUnwrap(store.category(id: category.id))
        reworded.guidance = "anyone asking for help"
        store.update(reworded)
        XCTAssertEqual(store.category(id: category.id)?.revision, before + 1)
    }

    func testAClassificationFromBeforeTheCategoryIsStale() {
        XCTAssertFalse(store.isStale(nil), "nothing to be behind on")

        let category = support()
        store.add(category)

        XCTAssertTrue(store.isStale(nil))
        XCTAssertTrue(store.isStale([:]))
        XCTAssertFalse(store.isStale(store.revisionsForModel))

        var reworded = category
        reworded.guidance = "anyone asking for help"
        store.update(reworded)
        XCTAssertTrue(store.isStale([category.id: 1]))
    }

    func testTheAssistantFindsACategoryByName() {
        store.add(support())
        XCTAssertEqual(store.named(in: "show me the support requests")?.name, "Support requests")
        XCTAssertEqual(store.named(in: "anything very important?")?.id, AITag.veryImportant.rawValue)
        XCTAssertNil(store.named(in: "what came in today"))
    }

    func testTheListSurvivesARoundTripAndKeepsNewBuiltIns() throws {
        store.add(support())
        store.setVisible(AITag.promotion.rawValue, false)
        let json = try XCTUnwrap(store.snapshotJSON)

        store.forgetAll()
        store.adopt(json: json)

        XCTAssertEqual(store.custom.count, 1)
        XCTAssertFalse(store.category(for: .promotion).isVisible)
        XCTAssertEqual(store.all.count, AITag.allCases.count + 1)
    }
}
