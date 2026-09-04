import SwiftUI
import UIKit

/// Teaching Maily to answer mail on your behalf.
///
/// A page, not a sheet, and built from the same parts as the onboarding
/// questions: progress at the top, the question big and left-aligned, the
/// answers as cards you tap, and Continue pinned to the bottom. The only
/// thing that should feel different from signing up is that it is longer,
/// because this is where somebody hands over authority.
///
/// Selection first. Typing is asked for exactly where a card cannot say it --
/// a price, a policy, a rule in their own words -- and never before Maily
/// knows enough to ask about the right ones. The step list is conditional:
/// what you picked decides what you are asked next, and a step with nothing
/// to ask is skipped rather than shown empty.
///
/// Twice along the way Maily stops asking and says what it understood, in the
/// model's words rather than the app's. Those screens are the point: a
/// summary the app assembled from its own fields could never be wrong, and so
/// would check nothing.
struct AutoReplySetupView: View {
    @Environment(AutoReplyStore.self) private var autoReply
    @Environment(\.dismiss) private var dismiss

    @State private var config: AutoReplyConfig
    @State private var index: Int
    @State private var understanding: AutoReplyUnderstanding?
    @State private var example: AutoReplyExample?
    @State private var isThinking = false
    @State private var failure: String?
    @State private var draftInstruction = ""

    /// A whole setup, or one question out of it.
    ///
    /// `singleStep` is the edit case: somebody who came to change what
    /// happens when Maily is unsure wants that question and a Save, not the
    /// eleven screens either side of it.
    private let singleStep: Bool

    init(
        editing existing: AutoReplyConfig? = nil,
        startingAt step: Step? = nil,
        singleStep: Bool = false
    ) {
        let config = existing ?? AutoReplyConfig()
        _config = State(initialValue: config)
        _understanding = State(initialValue: config.understanding)
        self.singleStep = singleStep
        let all = Step.allCases
        _index = State(initialValue: step.flatMap { all.firstIndex(of: $0) } ?? 0)
    }

    // MARK: - The step graph

    enum Step: String, CaseIterable {
        case intro, persona, work, audience, checkpoint, inbound
        case knowledge, pricing, availability, policies
        case allowed, boundaries, unsure, style, instructions
        case summary, example, done
    }

    /// The steps this particular setup asks for, in order. Conditional, so
    /// nobody is asked for a price they said Maily should never quote.
    private var steps: [Step] {
        if singleStep { return Step.allCases }
        return Step.allCases.filter { step in
            switch step {
            case .pricing:
                config.allowed.contains(.pricing) || config.inbound.contains("pricing")
            case .availability:
                config.allowed.contains(.availability) || config.inbound.contains("availability")
            default:
                true
            }
        }
    }

    private var step: Step { steps[min(index, steps.count - 1)] }

    private var progress: Double {
        guard index > 0 else { return 0 }
        return min(1, Double(index) / Double(max(1, steps.count - 2)))
    }

    private var canGoBack: Bool { index > 0 && step != .done }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !singleStep && step != .intro && step != .done {
                ProgressView(value: progress)
                    .tint(Color.accentColor)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            if let button = buttonTitle {
                Button(action: advance) {
                    Group {
                        if isThinking {
                            ProgressView().tint(.white)
                        } else {
                            Text(button).fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue || isThinking)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(singleStep || step == .intro || step == .done ? "" : "Auto-Reply")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!singleStep)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if canGoBack && !singleStep {
                    FlowBackButton {
                        withAnimation(.snappy(duration: 0.22)) { index -= 1 }
                    }
                } else if step == .intro {
                    FlowCloseButton { dismiss() }
                }
            }
        }
        .keyboardDismissable()
        .hidesTabBar()
        .animation(.snappy(duration: 0.25), value: index)
        .alert("That didn't work", isPresented: .constant(failure != nil)) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: - Moving

    private var buttonTitle: String? {
        if singleStep { return "Save" }
        return switch step {
        case .intro: "Set up Auto-Reply"
        case .checkpoint, .summary: "That looks right"
        case .example: "Looks good"
        case .done: "Complete setup"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .persona: config.persona != nil
        case .work: !config.workTopics.isEmpty
        case .allowed: !config.allowed.isEmpty
        case .checkpoint, .summary: understanding != nil
        case .example: example != nil
        default: true
        }
    }

    private func advance() {
        // One question, one Save. Nobody editing "when unsure" wants to be
        // walked through the ten screens after it.
        if singleStep {
            config.instructions = AutoReplyStore.tidied(config.instructions)
            autoReply.complete(config)
            dismiss()
            return
        }
        if step == .done {
            finish()
            return
        }
        withAnimation(.snappy(duration: 0.25)) { index += 1 }
        prepareIfNeeded()
    }

    /// The two screens that need the model run themselves as they arrive,
    /// rather than making somebody tap to find out what Maily thinks.
    private func prepareIfNeeded() {
        switch step {
        case .checkpoint, .summary:
            guard understanding == nil else { return }
            Task { await loadUnderstanding() }
        case .example:
            guard example == nil else { return }
            Task { await loadExample() }
        default:
            break
        }
    }

    private func labels(_ ids: Set<String>) -> [String] {
        guard let persona = config.persona else { return Array(ids).sorted() }
        let all = AutoReplyOptions.work(for: persona)
            + AutoReplyOptions.audience(for: persona)
            + AutoReplyOptions.inbound(for: persona)
            + AutoReplyOptions.policies(for: persona)
        return ids.compactMap { id in all.first { $0.id == id }?.label }.sorted()
    }

    private func loadUnderstanding() async {
        isThinking = true
        defer { isThinking = false }
        do {
            let result = try await AIService.autoReplyUnderstanding(config.payload(labels: labels))
            understanding = result
            config.understanding = result
        } catch {
            failure = error.localizedDescription
        }
    }

    private func loadExample() async {
        isThinking = true
        defer { isThinking = false }
        do {
            example = try await AIService.autoReplyExample(config.payload(labels: labels))
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Any answer changing makes the summary stale, and a summary of the old
    /// answers is worse than none.
    private func invalidateUnderstanding() {
        understanding = nil
        example = nil
        config.understanding = nil
    }

    /// Jumps back to the step a summary section came from, so Edit lands on
    /// the question rather than on a wall of everything.
    private func edit(_ named: String) {
        guard let target = Step(rawValue: named),
              let position = steps.firstIndex(of: target)
        else { return }
        invalidateUnderstanding()
        withAnimation(.snappy(duration: 0.25)) { index = position }
    }

    private func finish() {
        autoReply.complete(config)
        Analytics.record(.autoReplySetUp, [
            "persona": .string(config.persona?.rawValue ?? "none"),
            "allowed": .int(config.allowed.count),
            "boundaries": .int(config.mustAsk.count),
            "instructions": .int(config.activeInstructions.count),
            "facts": .int(config.business.filled.count),
        ])
        dismiss()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro:        AutoReplyIntroStep()
        case .persona:      personaStep
        case .work:         workStep
        case .audience:     audienceStep
        case .checkpoint:   understandingStep("Here's what I've understood so far.")
        case .inbound:      inboundStep
        case .knowledge:    knowledgeStep
        case .pricing:      pricingStep
        case .availability: availabilityStep
        case .policies:     policiesStep
        case .allowed:      allowedStep
        case .boundaries:   boundariesStep
        case .unsure:       unsureStep
        case .style:        styleStep
        case .instructions: instructionsStep
        case .summary:      understandingStep("Here's what Maily knows about you.")
        case .example:      exampleStep
        case .done:         doneStep
        }
    }

    private var personaStep: some View {
        AutoReplyStep("What best describes what you do?",
                   "This decides what Maily asks you next.") {
            OptionGrid(
                options: AutoReplyConfig.Persona.allCases.map {
                    AutoReplyOptions.Option($0.rawValue, $0.title, $0.symbol)
                },
                selected: Set([config.persona?.rawValue].compactMap { $0 })
            ) { id in
                config.persona = AutoReplyConfig.Persona(rawValue: id)
                config.workTopics = []
                config.audience = []
                config.inbound = []
                config.policies = [:]
                invalidateUnderstanding()
            }
        }
    }

    private var workStep: some View {
        let persona = config.persona ?? .other
        return AutoReplyStep(AutoReplyOptions.workTitle(for: persona),
                          "Pick everything that applies.") {
            OptionGrid(options: AutoReplyOptions.work(for: persona), selected: config.workTopics) { id in
                toggle(id, in: \.workTopics)
            }
        }
    }

    private var audienceStep: some View {
        let persona = config.persona ?? .other
        return AutoReplyStep("Who writes to you?",
                          "Maily uses this to judge who a message is from.") {
            OptionGrid(options: AutoReplyOptions.audience(for: persona), selected: config.audience) { id in
                toggle(id, in: \.audience)
            }
        }
    }

    private var inboundStep: some View {
        let persona = config.persona ?? .other
        return AutoReplyStep("What do they usually ask about?",
                          "The things you find yourself answering again and again.") {
            OptionGrid(options: AutoReplyOptions.inbound(for: persona), selected: config.inbound) { id in
                toggle(id, in: \.inbound)
            }
        }
    }

    private var knowledgeStep: some View {
        AutoReplyStep("Anything Maily should be able to state?",
                   "Only what you're happy for it to tell somebody. Everything you leave blank, it brings back to you instead of guessing.") {
            VStack(spacing: 14) {
                FieldBlock(label: "Your name or brand", hint: "How people know you.", text: $config.business.brand)
                FieldBlock(label: "What you do", hint: "One or two lines.", text: $config.business.whatItDoes)
                FieldBlock(label: "Common questions", hint: "Paste the ones you answer constantly.", text: $config.business.faq)
                FieldBlock(label: "Links", hint: "Site, booking page, docs.", text: $config.business.links)
                FieldBlock(label: "Anything else", hint: "Optional.", text: $config.business.notes)
            }
        }
    }

    private var pricingStep: some View {
        AutoReplyStep("How should Maily handle pricing?",
                   "Most people's answer is \"it depends\", and that is a real answer here.") {
            VStack(spacing: 9) {
                ForEach(AutoReplyConfig.PricingMode.allCases) { mode in
                    OptionRowCard(label: mode.title, symbol: mode.symbol, isSelected: config.pricing == mode) {
                        config.pricing = mode
                        invalidateUnderstanding()
                    }
                }
                if config.pricing.needsDetail {
                    FieldBlock(
                        label: config.pricing == .range ? "Your starting range" : "Your standard price",
                        hint: "Exactly as you'd say it out loud.",
                        text: $config.business.pricing
                    )
                    .padding(.top, 4)
                }
            }
        }
    }

    private var availabilityStep: some View {
        AutoReplyStep("How should Maily handle availability?",
                   "Committing your time is the easiest thing to get wrong.") {
            VStack(spacing: 9) {
                ForEach(AutoReplyConfig.AvailabilityMode.allCases) { mode in
                    OptionRowCard(label: mode.title, symbol: mode.symbol, isSelected: config.availability == mode) {
                        config.availability = mode
                        invalidateUnderstanding()
                    }
                }
                if config.availability.needsDetail {
                    FieldBlock(label: "Your usual availability",
                               hint: "e.g. Taking new work from March.",
                               text: $config.business.availability)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var policiesStep: some View {
        let persona = config.persona ?? .other
        return AutoReplyStep("Any rules Maily should know?",
                          "Pick the ones you actually have. You'll write each in one line.") {
            VStack(spacing: 9) {
                ForEach(AutoReplyOptions.policies(for: persona)) { option in
                    OptionRowCard(
                        label: option.label,
                        symbol: option.symbol,
                        isSelected: config.policies[option.id] != nil
                    ) {
                        if config.policies[option.id] == nil {
                            config.policies[option.id] = ""
                        } else {
                            config.policies.removeValue(forKey: option.id)
                        }
                        invalidateUnderstanding()
                    }

                    if config.policies[option.id] != nil {
                        FieldBlock(
                            label: AutoReplyOptions.policyLabel(option.id),
                            hint: AutoReplyOptions.policyHint(option.id),
                            text: Binding(
                                get: { config.policies[option.id] ?? "" },
                                set: { config.policies[option.id] = $0 }
                            )
                        )
                        .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    private var allowedStep: some View {
        AutoReplyStep("Which of these can Maily answer without you?",
                   "Only what you pick here is ever eligible for an automatic reply.") {
            VStack(spacing: 9) {
                ForEach(AutoReplyConfig.Category.allCases) { category in
                    OptionRowCard(
                        label: category.title,
                        symbol: category.symbol,
                        isSelected: config.allowed.contains(category)
                    ) {
                        if config.allowed.contains(category) {
                            config.allowed.remove(category)
                        } else {
                            config.allowed.insert(category)
                        }
                        invalidateUnderstanding()
                    }
                }
            }
        }
    }

    private var boundariesStep: some View {
        AutoReplyStep("What should always come back to you?",
                   "These beat everything else. Even where a message looks answerable, anything here stops and waits.") {
            VStack(spacing: 9) {
                ForEach(AutoReplyConfig.Boundary.allCases) { boundary in
                    OptionRowCard(
                        label: boundary.title,
                        symbol: nil,
                        isSelected: config.mustAsk.contains(boundary),
                        note: boundary.isRecommended ? "Recommended" : nil
                    ) {
                        if config.mustAsk.contains(boundary) {
                            config.mustAsk.remove(boundary)
                        } else {
                            config.mustAsk.insert(boundary)
                        }
                        invalidateUnderstanding()
                    }
                }
            }
        }
    }

    private var unsureStep: some View {
        AutoReplyStep("When Maily isn't sure, what should it do?",
                   "This is what happens whenever a message is near the line rather than clearly inside it.") {
            VStack(spacing: 9) {
                ForEach(AutoReplyConfig.Escalation.allCases) { option in
                    OptionRowCard(
                        label: option.title,
                        detail: option.detail,
                        symbol: nil,
                        isSelected: config.whenUnsure == option
                    ) {
                        config.whenUnsure = option
                        invalidateUnderstanding()
                    }
                }
            }
        }
    }

    private var styleStep: some View {
        AutoReplyStep("How should it sound?",
                   "Maily already knows your writing style. This is for the replies it sends on your behalf.") {
            VStack(alignment: .leading, spacing: 18) {
                PickerRow("Tone", AutoReplyConfig.Style.Tone.allCases, selection: $config.style.tone)
                PickerRow("Length", AutoReplyConfig.Style.Length.allCases, selection: $config.style.length)
                PickerRow("Warmth", AutoReplyConfig.Style.Warmth.allCases, selection: $config.style.warmth)
                PickerRow("Formality", AutoReplyConfig.Style.Formality.allCases, selection: $config.style.formality)
                PickerRow("Emojis", AutoReplyConfig.Style.Emojis.allCases, selection: $config.style.emojis)

                Toggle("Learn from my edits", isOn: $config.style.learnFromEdits)
                    .font(.subheadline)
            }
        }
    }

    private var instructionsStep: some View {
        AutoReplyStep("Any specific rules for Auto-Reply?",
                   "Give Maily rules about how you want your replies to behave. Optional, and you can change them any time.") {
            VStack(alignment: .leading, spacing: 12) {
                InstructionEditor(instructions: $config.instructions, draft: $draftInstruction)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("These change how Maily writes, not what it knows. A price or a policy belongs in the earlier questions, where Maily is allowed to state it as fact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func understandingStep(_ title: String) -> some View {
        AutoReplyStep(title, "Everything here comes from what you chose. Read it and correct anything that isn't you.") {
            AutoReplyUnderstandingView(
                understanding: understanding,
                isThinking: isThinking,
                onEdit: edit
            )
        }
    }

    private var exampleStep: some View {
        AutoReplyStep("This is how it would reply.",
                   "Written from your setup, for a message you'd actually get.") {
            AutoReplyExampleView(
                example: example,
                isThinking: isThinking,
                onRegenerate: {
                    example = nil
                    Task { await loadExample() }
                },
                onEditRules: { edit("instructions") }
            )
        }
    }

    private var doneStep: some View {
        AutoReplyDoneView(
            allowed: config.allowed.count,
            boundaries: config.mustAsk.count,
            escalation: config.whenUnsure.title
        )
    }

    private func toggle(_ id: String, in path: WritableKeyPath<AutoReplyConfig, Set<String>>) {
        withAnimation(.snappy(duration: 0.18)) {
            if config[keyPath: path].contains(id) {
                config[keyPath: path].remove(id)
            } else {
                config[keyPath: path].insert(id)
            }
        }
        invalidateUnderstanding()
    }
}
