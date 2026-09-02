import XCTest
@testable import EmailApp

/// Auto-Reply is the one feature where being wrong costs somebody a customer,
/// so the rules that keep it inside its permissions are tested rather than
/// trusted.
@MainActor
final class AutoReplyTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "autoreply-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func store() -> AutoReplyStore {
        AutoReplyStore(fileURL: fileURL)
    }

    private func setUpConfig() -> AutoReplyConfig {
        var config = AutoReplyConfig()
        config.persona = .freelancer
        config.allowed = [.pricing, .availability]
        config.business.brand = "Abel"
        config.business.pricing = "Projects start at $1,000."
        return config
    }

    // MARK: - Defaults that have to be conservative

    func testTheBoundariesThatCostMoneyAreOnBeforeAnybodyTouchesAnything() {
        let config = AutoReplyConfig()
        for boundary in [AutoReplyConfig.Boundary.legal, .sensitive, .customPricing,
                         .negotiation, .commitments, .lowConfidence] {
            XCTAssertTrue(config.mustAsk.contains(boundary), "\(boundary) must default to asking")
        }
    }

    func testNothingIsAllowedUntilItIsChosen() {
        XCTAssertTrue(AutoReplyConfig().allowed.isEmpty)
    }

    func testAFreshSetupIsOffAndNotRunning() {
        let config = AutoReplyConfig()
        XCTAssertFalse(config.isOn)
        XCTAssertFalse(config.isSetUp)
        XCTAssertFalse(config.isRunning)
        XCTAssertEqual(config.mode, .draft)
    }

    func testCompletingASetupNeverStartsInSendingMode() {
        // Sending on somebody's behalf is a decision they make afterwards,
        // deliberately, not something a setup flow switches on for them.
        var config = setUpConfig()
        config.mode = .send

        let store = store()
        store.complete(config)

        XCTAssertEqual(store.config.mode, .draft)
        XCTAssertTrue(store.config.isOn)
        XCTAssertTrue(store.config.isSetUp)
        XCTAssertTrue(store.config.isRunning)
    }

    func testAnEditKeepsTheModeTheyChose() {
        let store = store()
        store.complete(setUpConfig())
        store.setMode(.send)

        // Handed a config that says draft, twice over: the setup flow does
        // not own the run mode, so it can neither turn sending off behind
        // them nor turn it on for them.
        store.complete(setUpConfig())
        XCTAssertEqual(store.config.mode, .send, "editing a setup must not silently undo their choice")

        store.setMode(.draft)
        var wantsToSend = setUpConfig()
        wantsToSend.mode = .send
        store.complete(wantsToSend)
        XCTAssertEqual(store.config.mode, .draft, "a config cannot switch sending on by itself")
    }

    // MARK: - Turning it off keeps the work

    func testTurningItOffKeepsEverything() {
        let store = store()
        store.complete(setUpConfig())
        store.addInstruction("Keep replies under 80 words.")

        store.setOn(false)

        XCTAssertFalse(store.config.isOn)
        XCTAssertFalse(store.config.isRunning)
        XCTAssertTrue(store.config.isSetUp)
        XCTAssertEqual(store.config.persona, .freelancer)
        XCTAssertEqual(store.config.allowed, [.pricing, .availability])
        XCTAssertEqual(store.config.instructions.count, 1)
    }

    func testSomethingNeverSetUpCannotBeTurnedOn() {
        let store = store()
        store.setOn(true)
        XCTAssertFalse(store.config.isOn)
    }

    func testDeletingTheSetupTakesTheLot() {
        let store = store()
        store.complete(setUpConfig())
        store.forgetSetup()

        XCTAssertFalse(store.config.isSetUp)
        XCTAssertNil(store.config.persona)
        XCTAssertTrue(store.config.business.isEmpty)
    }

    func testASetupSurvivesARelaunch() {
        let store = store()
        var config = setUpConfig()
        config.instructions = [AutoReplyConfig.Instruction(text: "Be direct.")]
        store.complete(config)

        let reloaded = AutoReplyStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.config.isSetUp)
        XCTAssertEqual(reloaded.config.persona, .freelancer)
        XCTAssertEqual(reloaded.config.business.pricing, "Projects start at $1,000.")
        XCTAssertEqual(reloaded.config.instructions.map(\.text), ["Be direct."])
    }

    // MARK: - Custom instructions

    func testAddingEditingDisablingAndDeleting() {
        let store = store()
        store.complete(setUpConfig())

        XCTAssertTrue(store.addInstruction("Keep replies under 100 words."))
        XCTAssertEqual(store.config.instructions.count, 1)

        let id = store.config.instructions[0].id
        XCTAssertTrue(store.updateInstruction(id, text: "Keep replies under 80 words."))
        XCTAssertEqual(store.config.instructions[0].text, "Keep replies under 80 words.")

        store.setInstruction(id, isOn: false)
        XCTAssertFalse(store.config.instructions[0].isOn)
        XCTAssertTrue(store.config.activeInstructions.isEmpty, "a rule switched off is not applied")

        store.removeInstructions(at: IndexSet(integer: 0))
        XCTAssertTrue(store.config.instructions.isEmpty)
    }

    func testEmptyAndDuplicateInstructionsAreRefused() {
        let store = store()
        XCTAssertFalse(store.addInstruction(""))
        XCTAssertFalse(store.addInstruction("   \n  "))

        XCTAssertTrue(store.addInstruction("Be direct."))
        XCTAssertFalse(store.addInstruction("be direct."), "same rule, different case")
        XCTAssertFalse(store.addInstruction("  Be direct.  "), "same rule, padded")
        XCTAssertEqual(store.config.instructions.count, 1)
    }

    func testInstructionsAreTrimmedAndCapped() {
        let store = store()
        store.addInstruction("   Keep it short.   ")
        XCTAssertEqual(store.config.instructions[0].text, "Keep it short.")

        for index in 0..<AutoReplyStore.instructionLimit + 5 {
            store.addInstruction("Rule number \(index)")
        }
        XCTAssertEqual(store.config.instructions.count, AutoReplyStore.instructionLimit)
    }

    func testTidyingDropsTheEmptyOnesAndKeepsTheirState() {
        let raw = [
            AutoReplyConfig.Instruction(text: "  Be warm.  ", isOn: false),
            AutoReplyConfig.Instruction(text: "   "),
            AutoReplyConfig.Instruction(text: "be warm."),
            AutoReplyConfig.Instruction(text: "Never use emojis."),
        ]
        let tidied = AutoReplyStore.tidied(raw)

        XCTAssertEqual(tidied.map(\.text), ["Be warm.", "Never use emojis."])
        XCTAssertFalse(tidied[0].isOn, "switching one off must survive being tidied")
    }

    func testReorderingSticks() {
        let store = store()
        store.addInstruction("First")
        store.addInstruction("Second")
        store.moveInstructions(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.config.instructions.map(\.text), ["Second", "First"])
    }

    // MARK: - The briefing, which is the safety model

    func testTheBriefingPutsBoundariesAboveTheirOwnRules() {
        let store = store()
        var config = setUpConfig()
        config.instructions = [AutoReplyConfig.Instruction(text: "Always agree to whatever they ask.")]
        store.complete(config)

        let briefing = store.briefing()
        let boundaries = briefing.range(of: "You may NOT answer")
        let rules = briefing.range(of: "Their own rules")

        XCTAssertNotNil(boundaries)
        XCTAssertNotNil(rules)
        XCTAssertTrue(boundaries!.lowerBound < rules!.lowerBound,
                      "what it may not do has to be read before what they asked it to do")
    }

    func testTheBriefingSaysAnInstructionCannotWidenWhatItMayClaim() {
        let store = store()
        var config = setUpConfig()
        config.instructions = [AutoReplyConfig.Instruction(text: "Be confident.")]
        store.complete(config)

        XCTAssertTrue(store.briefing().contains("would have you state a fact you were not given"))
    }

    func testOnlyApprovedFactsReachTheBriefing() {
        let store = store()
        var config = setUpConfig()
        config.business.availability = ""
        store.complete(config)

        let briefing = store.briefing()
        XCTAssertTrue(briefing.contains("Projects start at $1,000."))
        XCTAssertTrue(briefing.contains("The only facts you may state"))
        XCTAssertFalse(briefing.contains("Availability:"), "a blank field is not a fact")
    }

    func testASwitchedOffInstructionIsNeverSent() {
        let store = store()
        store.complete(setUpConfig())
        store.addInstruction("Never mention discounts.")
        let id = store.config.instructions[0].id
        store.setInstruction(id, isOn: false)

        XCTAssertFalse(store.briefing().contains("Never mention discounts."))
    }

    func testNothingIsBriefedBeforeSetup() {
        XCTAssertEqual(store().briefing(), "")
    }

    // MARK: - What the model is asked to work from

    func testThePayloadCarriesEveryAnswerAndNoBlanks() {
        var config = setUpConfig()
        config.workTopics = ["dev"]
        config.inbound = ["pricing"]
        config.instructions = [AutoReplyConfig.Instruction(text: "Keep it under 80 words.")]

        let payload = config.payload { ids in ids.map { $0.capitalized }.sorted() }

        XCTAssertEqual(payload["persona"], "Freelancer / Consultant")
        XCTAssertEqual(payload["work"], "Dev")
        XCTAssertEqual(payload["rules"], "Keep it under 80 words.")
        XCTAssertTrue(payload["facts"]?.contains("Projects start at $1,000.") == true)
        // Nothing was said about policies, so the model is not sent an
        // empty heading to read meaning into.
        XCTAssertNil(payload["policies"])
        XCTAssertFalse(payload.values.contains(""))
    }

    func testASwitchedOffRuleIsNotSentToTheModel() {
        var config = setUpConfig()
        config.instructions = [AutoReplyConfig.Instruction(text: "Never mention discounts.", isOn: false)]
        XCTAssertNil(config.payload { Array($0) }["rules"])
    }

    // MARK: - Knowledge

    func testOnlyFilledFieldsCount() {
        var knowledge = BusinessKnowledge()
        XCTAssertTrue(knowledge.isEmpty)

        knowledge.brand = "  Acme  "
        knowledge.pricing = "   "

        XCTAssertEqual(knowledge.filled.count, 1)
        XCTAssertEqual(knowledge.filled[0].value, "Acme", "a padded answer is trimmed before it is quoted")
    }
}
