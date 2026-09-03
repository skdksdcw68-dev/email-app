import SwiftUI

/// Connecting a mailbox, as a process rather than a button.
///
/// Built from the same parts as `AutoReplySetupView`: a flat step enum, an
/// index into a *computed* list of steps so a step with nothing to ask is
/// skipped rather than shown empty, progress at the top, one pinned button at
/// the bottom whose label changes per step. Consistency here is not tidiness
/// -- somebody who has been through Auto-Reply's setup already knows how this
/// screen works.
///
/// The old version was a row that pushed the same page as "Manage accounts"
/// and a permanently disabled button captioned "not built yet".
struct AddMailboxFlow: View {
    @Environment(MailStore.self) private var mail
    @Environment(\.dismiss) private var dismiss

    /// The first mailbox, during onboarding. Naming and colouring a mailbox
    /// only means anything when there is more than one, so those steps are
    /// dropped and the flow ends by getting out of the way.
    var firstRun = false
    /// Called when a mailbox was actually connected.
    var onFinish: (() -> Void)? = nil

    @State private var index = 0
    @State private var provider: MailProvider?
    @State private var nickname = ""
    @State private var tint: MailboxTint = .blue
    @State private var window: ImportWindow = .threeMonths
    @State private var failure: String?

    // MARK: - The step graph

    enum Step: String, CaseIterable {
        case provider
        case googleConsent
        case naming
        case importScope
        case importing
        case done
    }

    private var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            // Nothing to name when there is only one, and nothing to tell
            // apart with a colour either.
            case .naming: !firstRun
            default: true
            }
        }
    }

    private var step: Step { steps[min(index, steps.count - 1)] }

    private var progress: Double {
        guard index > 0 else { return 0 }
        return min(1, Double(index) / Double(max(1, steps.count - 2)))
    }

    private var canGoBack: Bool {
        index > 0 && step != .importing && step != .done
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if step != .provider && step != .done {
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
                            if mail.isConnecting {
                                ProgressView().tint(.white)
                            } else {
                                Text(button).fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canContinue || mail.isConnecting)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle(step == .provider || step == .done ? "" : "Add mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if canGoBack {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { index -= 1 }
                        } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                    } else if !firstRun && (step == .provider || step == .importing) {
                        // Closeable during the import, and that is the point.
                        // The work is not owned by this screen: the task
                        // outlives it, `MailStore` holds the mail, and
                        // `ImportLedger` resumes what is left. Sitting and
                        // watching a ring for four minutes is not something
                        // to ask of anybody.
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Close")
                    }
                }
            }
            .keyboardDismissable()
            .animation(.snappy(duration: 0.25), value: index)
            .alert("That didn't work", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
        // Nothing here closes on a swipe -- a half-answered flow should not
        // vanish because a finger moved. The X is the way out, and during
        // the import it is offered rather than withheld.
        .interactiveDismissDisabled()
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .provider:   providerStep
        case .googleConsent: consentStep
        case .naming:     namingStep
        case .importScope: scopeStep
        case .importing:  importingStep
        case .done:       doneStep
        }
    }

    private var providerStep: some View {
        AutoReplyStep(
            firstRun ? "Connect your inbox" : "Add a mailbox",
            "Maily works with one at a time and switches between them."
        ) {
            VStack(spacing: 9) {
                ForEach(MailProvider.allCases, id: \.self) { option in
                    OptionRowCard(
                        label: option.title,
                        detail: option.subtitle,
                        symbol: symbol(for: option),
                        isSelected: provider == option,
                        // Said plainly rather than by greying the row out
                        // with no reason. These are next, not never.
                        note: option == .gmail ? nil : "Coming soon"
                    ) {
                        guard option == .gmail else { return }
                        provider = option
                    }
                    .disabled(option != .gmail)
                    .opacity(option == .gmail ? 1 : 0.5)
                }
            }
        }
    }

    private var consentStep: some View {
        AutoReplyStep(
            "What Maily will be allowed to do",
            "Google asks you to confirm this on the next screen."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                permission("Read your mail", "So it can sort it, summarise it and answer questions about it.")
                permission("Create drafts and send", "Only when you ask, and every reply is shown to you first.")

                Divider().padding(.vertical, 4)

                Text("Maily cannot archive, delete or star mail. That needs a further Gmail permission this app deliberately does not ask for.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Your mail is read on this phone. It is not copied to a server of ours.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var namingStep: some View {
        AutoReplyStep(
            "Name it",
            "So you can tell it from the others at a glance."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                FieldBlock(label: "Name", hint: "Work", text: $nickname)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Colour").font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        ForEach(MailboxTint.allCases, id: \.self) { swatch in
                            Button {
                                tint = swatch
                            } label: {
                                Circle()
                                    .fill(swatch.color)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if tint == swatch {
                                            Image(systemName: "checkmark")
                                                .font(.footnote.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var scopeStep: some View {
        AutoReplyStep(
            "How much to bring over",
            "Older mail is still searchable in Gmail either way."
        ) {
            VStack(spacing: 9) {
                ForEach(ImportWindow.allCases, id: \.self) { option in
                    OptionRowCard(
                        label: option.title,
                        detail: option.detail,
                        symbol: nil,
                        isSelected: window == option
                    ) {
                        window = option
                    }
                }
            }
        }
    }

    private var importingStep: some View {
        AutoReplyStep("Bringing your mail over", nil) {
            ImportingMailView(progress: mail.importProgress, canLeave: !firstRun)
                .frame(minHeight: 320)
        }
    }

    private var doneStep: some View {
        AutoReplyStep(
            mail.account.map { "\($0.address) is ready" } ?? "Ready",
            "You can switch between mailboxes from the inbox, or from You."
        ) {
            EmptyView()
        }
    }

    private func permission(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func symbol(for provider: MailProvider) -> String {
        switch provider {
        case .gmail:     "envelope.fill"
        case .microsoft: "square.grid.2x2.fill"
        case .imap:      "server.rack"
        }
    }

    // MARK: - Moving

    private var buttonTitle: String? {
        switch step {
        case .provider:      "Continue"
        case .googleConsent: "Sign in with Google"
        case .naming:        "Continue"
        case .importScope:   "Bring it over"
        case .importing:     nil
        case .done:          firstRun ? "Start using Maily" : "Done"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .provider: provider != nil
        default: true
        }
    }

    private func advance() {
        switch step {
        case .googleConsent:
            Task { await connect() }
        case .importScope:
            Task { await runImport() }
        case .done:
            onFinish?()
            dismiss()
        default:
            withAnimation(.snappy(duration: 0.25)) { index += 1 }
        }
    }

    /// The consent screen, and then a check nothing else does: is this
    /// mailbox already here?
    ///
    /// Without it, adding an account you already have looks like it worked
    /// and quietly changes nothing, because the id derives from the address
    /// and lands on the record that already exists.
    private func connect() async {
        await mail.connect()

        if let error = mail.connectionError {
            failure = error
            return
        }
        guard mail.isConnected else { return }

        withAnimation(.snappy(duration: 0.25)) { index += 1 }
    }

    private func runImport() async {
        if let id = mail.account?.id {
            mail.registry.update(id) {
                $0.importWindow = window
                if !firstRun {
                    $0.tint = tint
                    let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    $0.nickname = trimmed.isEmpty ? nil : trimmed
                }
            }
        }
        withAnimation(.snappy(duration: 0.25)) { index += 1 }
        await mail.importRecentMail()
        withAnimation(.snappy(duration: 0.25)) { index += 1 }
    }
}
