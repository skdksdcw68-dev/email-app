import SwiftUI

/// Everything Auto-Reply knows, as a list you can go straight into.
///
/// Editing a setup is not the same act as making one. Somebody who wants to
/// add a category or change what happens when Maily is unsure should not be
/// walked through eleven screens to reach the one they meant -- so this shows
/// what is there, with the current answer on every row, and each row opens
/// only its own question.
///
/// A page, not a sheet, like the setup itself: it has its own back stack, and
/// coming back from a question should land here rather than closing the lot.
struct AutoReplyEditView: View {
    @Environment(AutoReplyStore.self) private var autoReply

    private var config: AutoReplyConfig { autoReply.config }

    var body: some View {
        List {
            Section {
                row("Who you are", config.persona?.title ?? "Not set", "person.fill", .persona)
                row("Your work", summary(config.workTopics), "briefcase.fill", .work)
                row("Who writes to you", summary(config.audience), "person.2.fill", .audience)
                row("What they ask about", summary(config.inbound), "questionmark.bubble.fill", .inbound)
            } header: {
                Text("About you")
            }

            Section {
                row("Facts Maily may state",
                    config.business.isEmpty ? "None" : "\(config.business.filled.count) things",
                    "brain.head.profile", .knowledge)
                row("Pricing", config.pricing.title, "tag.fill", .pricing)
                row("Availability", config.availability.title, "calendar.badge.clock", .availability)
                row("Your rules and policies",
                    config.policies.isEmpty ? "None" : "\(config.policies.count) written down",
                    "doc.text.fill", .policies)
            } header: {
                Text("What it knows")
            } footer: {
                Text("Maily can only state facts you gave it. Everything else comes back to you.")
            }

            Section {
                row("What it may answer", "\(config.allowed.count) kinds of mail",
                    "checkmark.circle.fill", .allowed)
                row("What always comes to you", "\(config.mustAsk.count) boundaries",
                    "hand.raised.fill", .boundaries)
                row("When it isn't sure", config.whenUnsure.title,
                    "questionmark.circle.fill", .unsure)
            } header: {
                Text("Permission")
            }

            Section {
                row("How it sounds", config.style.tone.title, "textformat", .style)
                NavigationLink {
                    AutoReplyInstructionsView()
                } label: {
                    label("Custom instructions", instructionSummary, "list.bullet.rectangle.fill")
                }
            } header: {
                Text("How it writes")
            } footer: {
                Text("Your rules are kept exactly as you wrote them and applied to every reply.")
            }

            Section {
                NavigationLink {
                    AutoReplySetupView(editing: config)
                } label: {
                    Label("Go through the whole setup again", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
            } footer: {
                Text("Your answers are already filled in. Only worth it if a lot has changed.")
            }
        }
        .navigationTitle("Edit setup")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }

    private var instructionSummary: String {
        let active = config.activeInstructions.count
        let total = config.instructions.count
        if total == 0 { return "None" }
        if active == total { return active == 1 ? "1 rule" : "\(active) rules" }
        return "\(active) of \(total) active"
    }

    /// One line, and the one question behind it.
    private func row(
        _ title: String,
        _ value: String,
        _ symbol: String,
        _ step: AutoReplySetupView.Step
    ) -> some View {
        NavigationLink {
            AutoReplySetupView(editing: config, startingAt: step, singleStep: true)
        } label: {
            label(title, value, symbol)
        }
    }

    private func label(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// The picked labels, or how many there are once a list gets long.
    private func summary(_ ids: Set<String>) -> String {
        guard let persona = config.persona, !ids.isEmpty else {
            return ids.isEmpty ? "Not set" : "\(ids.count) chosen"
        }
        let all = AutoReplyOptions.work(for: persona)
            + AutoReplyOptions.audience(for: persona)
            + AutoReplyOptions.inbound(for: persona)
        let labels = ids.compactMap { id in all.first { $0.id == id }?.label }.sorted()
        guard !labels.isEmpty else { return "\(ids.count) chosen" }
        return labels.count <= 2 ? labels.joined(separator: ", ") : "\(labels.count) chosen"
    }
}
