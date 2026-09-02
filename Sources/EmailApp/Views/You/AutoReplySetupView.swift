import SwiftUI

/// Teaching Maily to answer mail on your behalf.
///
/// Deliberately long. Everything else in the app is one tap; this is the one
/// place where a person hands over authority, and a flow that took ten
/// seconds would be telling them it does not matter much. Each step asks one
/// thing, and what it asks depends on what they said they do -- a student and
/// a founder are not given the same twelve questions.
///
/// Nothing is saved until the last screen. Opening it again with a setup
/// already in place starts from those answers rather than from nothing.
struct AutoReplySetupView: View {
    @Environment(AutoReplyStore.self) private var autoReply
    @Environment(\.dismiss) private var dismiss

    @State private var config: AutoReplyConfig
    @State private var step: Step = .intro
    @State private var draftInstruction = ""

    init(editing existing: AutoReplyConfig? = nil) {
        _config = State(initialValue: existing ?? AutoReplyConfig())
    }

    private enum Step: Int, CaseIterable {
        case intro, persona, work, knowledge, allowed, boundaries
        case unsure, instructions, review, preview, done

        /// How far along the bar is. The intro is not progress and the last
        /// screen is not a step, so neither moves it.
        var fraction: Double {
            guard self != .intro else { return 0 }
            let steps = Double(Step.allCases.count - 2)
            return min(1, Double(rawValue) / steps)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step != .intro && step != .done {
                    ProgressView(value: step.fraction)
                        .tint(.accentColor)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                }

                ScrollView {
                    content
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .done {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .principal) {
                    if step != .intro && step != .done {
                        Text("Auto-Reply")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.snappy(duration: 0.28), value: step)
        }
        .interactiveDismissDisabled(step != .intro)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro:        intro
        case .persona:      personaStep
        case .work:         workStep
        case .knowledge:    knowledgeStep
        case .allowed:      allowedStep
        case .boundaries:   boundariesStep
        case .unsure:       unsureStep
        case .instructions: instructionsStep
        case .review:       reviewStep
        case .preview:      previewStep
        case .done:         doneStep
        }
    }

    // MARK: - Moving

    private func go(_ next: Step) {
        step = next
    }

    private var afterPersona: Step { .work }

    // MARK: - Steps

    private var intro: some View {
        StepShell(
            eyebrow: nil,
            title: "Let Maily handle the routine replies.",
            subtitle: "Tell it what you do, what it may answer, and what should always come back to you.",
            button: "Set up Auto-Reply",
            action: { go(.persona) }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                introPoint("checkmark.shield.fill", "It only answers what you allow",
                           "Everything else comes to you, untouched.")
                introPoint("square.and.pencil", "It writes, you send",
                           "Maily starts by drafting. Sending on its own is a switch you throw later, not something it decides.")
                introPoint("lock.fill", "It never invents anything",
                           "It can only state facts you gave it. If it needs something it does not have, it asks you.")
            }
            .padding(.top, 4)

            Button("Not now") { dismiss() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private func introPoint(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var personaStep: some View {
        StepShell(
            eyebrow: "About you",
            title: "What best describes your work?",
            subtitle: "This decides what Maily asks you next, so it is worth getting roughly right.",
            button: config.persona == nil ? nil : "Continue",
            action: { go(afterPersona) }
        ) {
            VStack(spacing: 8) {
                ForEach(AutoReplyConfig.Persona.allCases) { persona in
                    ChoiceRow(
                        title: persona.title,
                        symbol: persona.symbol,
                        isOn: config.persona == persona
                    ) {
                        config.persona = persona
                    }
                }
            }
        }
    }

    private var workStep: some View {
        StepShell(
            eyebrow: config.persona?.title,
            title: config.persona?.prompt ?? "Tell Maily about your work.",
            subtitle: "These become the only facts Maily may state on your behalf. Leave anything blank that does not apply.",
            button: "Continue",
            action: { go(.knowledge) }
        ) {
            VStack(spacing: 14) {
                ForEach(workFields, id: \.label) { field in
                    FieldBlock(label: field.label, hint: field.hint, text: field.text)
                }
            }
        }
    }

    /// The questions that belong to this persona, and only those.
    private var workFields: [(label: String, hint: String, text: Binding<String>)] {
        let business = Binding(get: { config.business }, set: { config.business = $0 })
        switch config.persona {
        case .founder:
            [("Company name", "Acme", business.brand),
             ("What does it do?", "In your own words.", business.whatItDoes),
             ("Who are your customers?", "Types or industries.", business.customers),
             ("What do you sell?", "Products or services.", business.offering)]
        case .freelancer:
            [("Your name or brand", "How clients know you.", business.brand),
             ("What do you offer?", "What people hire you for.", business.offering),
             ("Typical clients", "Startups, agencies, founders…", business.customers),
             ("What work do you take?", "And what you turn down.", business.acceptedWork)]
        case .agency:
            [("Studio name", "Brand name.", business.brand),
             ("What do you provide?", "Main services.", business.offering),
             ("Industries you serve", "Who you work with.", business.customers),
             ("How a new project starts", "Brief, call, qualification…", business.acceptedWork)]
        case .sales:
            [("What are you selling?", "Product or service.", business.offering),
             ("Ideal customers", "Who it is for.", business.customers),
             ("What qualifies a lead?", "Budget, timeline, need.", business.acceptedWork)]
        case .support:
            [("Product name", "What customers call it.", business.brand),
             ("What does it do?", "Short description.", business.whatItDoes),
             ("Top support questions", "Paste your FAQs.", business.faq)]
        case .manager:
            [("Team or organisation", "Name.", business.brand),
             ("What do you coordinate?", "Scheduling, projects, people…", business.whatItDoes),
             ("What can Maily coordinate?", "The routine parts.", business.acceptedWork)]
        case .developer:
            [("What do you build?", "Apps, SaaS, integrations…", business.offering),
             ("Technical scope", "Languages, platforms, areas.", business.whatItDoes),
             ("What requests do you take?", "And what you decline.", business.acceptedWork)]
        case .creator:
            [("Brand or creator name", "How people know you.", business.brand),
             ("What is your niche?", "Content or business focus.", business.whatItDoes),
             ("Collaboration types", "Sponsorships, UGC, partnerships…", business.offering)]
        case .student, .personal, .other, .none:
            [("What is your email mostly?", "Applications, projects, admin…", business.whatItDoes),
             ("What can Maily help with?", "The low-risk, repetitive parts.", business.acceptedWork)]
        }
    }

    private var knowledgeStep: some View {
        StepShell(
            eyebrow: "What Maily may say",
            title: "Anything it should be able to state?",
            subtitle: "Only fill in what you are happy for Maily to tell somebody. Everything you leave blank, it will bring back to you instead of guessing.",
            button: "Continue",
            action: { go(.allowed) }
        ) {
            VStack(spacing: 14) {
                FieldBlock(label: "Pricing", hint: "Only what you would say out loud.", text: $config.business.pricing)
                FieldBlock(label: "Availability", hint: "Taking work? Booked until when?", text: $config.business.availability)
                FieldBlock(label: "Hours", hint: "Mon–Fri, 9–6.", text: $config.business.hours)
                FieldBlock(label: "Where you work", hint: "Regions or time zones.", text: $config.business.regions)
                FieldBlock(label: "Policies", hint: "Refunds, cancellations, terms.", text: $config.business.policies)
                FieldBlock(label: "Common questions", hint: "Paste the ones you answer constantly.", text: $config.business.faq)
                FieldBlock(label: "Links", hint: "Site, booking page, docs.", text: $config.business.links)
                FieldBlock(label: "Escalate to", hint: "Who a hard one should go to.", text: $config.business.escalationContact)
                FieldBlock(label: "Anything else", hint: "Whatever else Maily should know.", text: $config.business.notes)
            }
        }
    }

    private var allowedStep: some View {
        StepShell(
            eyebrow: "Permission",
            title: "What should Maily handle?",
            subtitle: "Pick the kinds of mail you are tired of answering yourself.",
            button: config.allowed.isEmpty ? nil : "Continue",
            action: { go(.boundaries) }
        ) {
            VStack(spacing: 8) {
                ForEach(AutoReplyConfig.Category.allCases) { category in
                    CheckRow(
                        title: category.title,
                        symbol: category.symbol,
                        isOn: config.allowed.contains(category)
                    ) {
                        if config.allowed.contains(category) {
                            config.allowed.remove(category)
                        } else {
                            config.allowed.insert(category)
                        }
                    }
                }

                if config.allowed.isEmpty {
                    Text("Pick at least one, or there is nothing for Maily to do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var boundariesStep: some View {
        StepShell(
            eyebrow: "Boundaries",
            title: "What should always come back to you?",
            subtitle: "These beat everything else. Even if a message looks like something Maily may answer, anything on this list stops and waits for you.",
            button: "Continue",
            action: { go(.unsure) }
        ) {
            VStack(spacing: 8) {
                ForEach(AutoReplyConfig.Boundary.allCases) { boundary in
                    CheckRow(
                        title: boundary.title,
                        symbol: nil,
                        isOn: config.mustAsk.contains(boundary),
                        note: boundary.isRecommended ? "Recommended" : nil
                    ) {
                        if config.mustAsk.contains(boundary) {
                            config.mustAsk.remove(boundary)
                        } else {
                            config.mustAsk.insert(boundary)
                        }
                    }
                }
            }
        }
    }

    private var unsureStep: some View {
        StepShell(
            eyebrow: "Uncertainty",
            title: "When Maily isn't sure, what should it do?",
            subtitle: "This is what happens whenever a message is close to the line rather than clearly inside it.",
            button: "Continue",
            action: { go(.instructions) }
        ) {
            VStack(spacing: 8) {
                ForEach(AutoReplyConfig.Escalation.allCases) { option in
                    ChoiceRow(
                        title: option.title,
                        detail: option.detail,
                        symbol: nil,
                        isOn: config.whenUnsure == option
                    ) {
                        config.whenUnsure = option
                    }
                }
            }
        }
    }

    // MARK: - Custom instructions

    private var instructionsStep: some View {
        StepShell(
            eyebrow: "Your rules",
            title: "Custom instructions",
            subtitle: "Give Maily any specific rules you want it to follow when replying.",
            button: "Review setup",
            action: {
                config.instructions = AutoReplyStore.tidied(config.instructions)
                go(.review)
            }
        ) {
            InstructionEditor(
                instructions: $config.instructions,
                draft: $draftInstruction
            )

            // The distinction that keeps a rule from becoming a claim.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("These change how Maily writes, not what it knows. A price or a policy belongs in the questions above, where Maily is allowed to state it as fact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            Text("Optional. You can add these later, and change them any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    // MARK: - Review

    private var reviewStep: some View {
        StepShell(
            eyebrow: "Review",
            title: "Here's what Maily learned.",
            subtitle: "Check it before switching it on. Maily will only use what is here, plus the email it is answering.",
            button: "See an example",
            action: { go(.preview) }
        ) {
            VStack(spacing: 10) {
                ReviewCard("You", config.persona?.title ?? "Not set", "person.fill") { go(.persona) }
                ReviewCard("Facts it may state",
                           config.business.isEmpty
                             ? "Nothing yet — it will ask you about everything"
                             : "\(config.business.filled.count) things you told it",
                           "brain.head.profile") { go(.work) }
                ReviewCard("It may answer", "\(config.allowed.count) kinds of mail", "checkmark.circle.fill") { go(.allowed) }
                ReviewCard("Always ask you", "\(config.mustAsk.count) boundaries", "hand.raised.fill") { go(.boundaries) }
                ReviewCard("When unsure", config.whenUnsure.title, "questionmark.circle.fill") { go(.unsure) }
                ReviewCard("Your rules",
                           config.activeInstructions.isEmpty
                             ? "None"
                             : "\(config.activeInstructions.count) active",
                           "list.bullet.rectangle.fill") { go(.instructions) }
            }
        }
    }

    // MARK: - Preview

    private var previewStep: some View {
        StepShell(
            eyebrow: "Example",
            title: "This is how it would reply.",
            subtitle: "Written from what you just told it. A real reply also reads the message and the thread it belongs to.",
            button: "Looks right",
            action: { go(.done) }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                PreviewBlock(title: "If somebody wrote", text: AutoReplyPreview.incoming(for: config))
                PreviewBlock(title: "Maily would answer", text: AutoReplyPreview.reply(for: config), isReply: true)

                if !config.activeInstructions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Following your rules")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(config.activeInstructions) { instruction in
                            Label(instruction.text, systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }

                Button("Change the rules") { go(.instructions) }
                    .font(.subheadline)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Done

    private var doneStep: some View {
        AutoReplyDoneView(
            handled: config.allowed.count,
            onFinish: {
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
        )
    }
}

// MARK: - The one screen that is not a form

/// The end of the setup. A tick that draws itself, and nothing else moving.
private struct AutoReplyDoneView: View {
    let handled: Int
    let onFinish: () -> Void

    @State private var isShown = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .scaleEffect(isShown ? 1 : 0.6)
                .opacity(isShown ? 1 : 0)

            Text("Auto-Reply is ready.")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text("Maily knows what it can handle and when to bring you in. It will write the replies and leave them for you — nothing is sent until you say so.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(handled) kinds of mail")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)

            Button(action: onFinish) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .padding(.top, 48)
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { isShown = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
