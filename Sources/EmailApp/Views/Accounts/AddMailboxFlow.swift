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

    // The IMAP half. Nothing here is written anywhere until it has been
    // proved to work -- the password especially, which goes to the Keychain
    // only once a server has accepted it.
    @State private var imapAddress = ""
    @State private var imapPassword = ""
    @State private var server = IMAPConfig(imapHost: "", smtpHost: "", username: "")
    @State private var showsServerFields = false
    @State private var isTesting = false
    @State private var probe: IMAPProbe.Progress?
    @State private var serverNote: String?

    // MARK: - The step graph

    enum Step: String, CaseIterable {
        case provider
        case googleConsent
        case imapSignIn
        case imapServer
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
            case .googleConsent: provider != .imap
            case .imapSignIn: provider == .imap
            // Only when the guess was wrong. Most people never see this, and
            // the ones who do are the ones who need it.
            case .imapServer: provider == .imap && showsServerFields
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
                        FlowBackButton {
                            withAnimation(.snappy(duration: 0.22)) { index -= 1 }
                        }
                    } else if !firstRun && (step == .provider || step == .importing) {
                        // Closeable during the import, and that is the point.
                        // The work is not owned by this screen: the task
                        // outlives it, `MailStore` holds the mail, and
                        // `ImportLedger` resumes what is left. Sitting and
                        // watching a ring for four minutes is not something
                        // to ask of anybody.
                        FlowCloseButton { dismiss() }
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
        case .imapSignIn: imapSignInStep
        case .imapServer: imapServerStep
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
                        // with no reason. Microsoft is next, not never.
                        note: option == .microsoft ? "Coming soon" : nil
                    ) {
                        guard option != .microsoft else { return }
                        provider = option
                    }
                    .disabled(option == .microsoft)
                    .opacity(option == .microsoft ? 0.5 : 1)
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

    /// Address and password, and nothing else.
    ///
    /// The whole design of this step is that nobody should have to know what
    /// IMAP is. They know their address and their password; the app works out
    /// the rest by trying, and only asks about hosts and ports if trying
    /// failed. Every other mail client leads with a form of six fields and
    /// loses people on the second one.
    private var imapSignInStep: some View {
        AutoReplyStep(
            "Sign in to your mailbox",
            "Works with business email, your own domain, and most providers."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                FieldBlock(label: "Email address", hint: "you@yourcompany.com", text: $imapAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)

                VStack(alignment: .leading, spacing: Style.tight) {
                    Text("Password").font(Style.rowTitleStrong)
                    SecureField("", text: $imapPassword)
                        .textContentType(.password)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .cardBackground()
                }

                if let warning = MailServerGuess.first(for: imapAddress).warning,
                   imapAddress.contains("@") {
                    Label(warning, systemImage: "info.circle")
                        .font(Style.rowDetail)
                        .foregroundStyle(Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isTesting {
                    searchProgress
                } else {
                    // Always offered, never buried behind a failure.
                    //
                    // Gmail's own app asks for the IMAP server, the port and
                    // the security type before it will try anything. Asking is
                    // worse for the many and essential for the few, so the app
                    // guesses first and keeps this here for anybody who
                    // already knows -- rather than making them fail once to
                    // earn the form.
                    Button("Enter server settings myself") {
                        server = MailServerGuess.first(for: imapAddress).config
                        withAnimation(.snappy(duration: 0.25)) {
                            showsServerFields = true
                            index += 1
                        }
                    }
                    .font(Style.rowDetail)
                    .disabled(!imapAddress.contains("@"))
                }

                Text("Your password is kept in this phone's Keychain and used only to reach your mail server. It is not sent anywhere else.")
                    .font(Style.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the search is doing, rather than a spinner that says nothing.
    ///
    /// A bare spinner on a job that can take half a minute reads as a hang,
    /// and somebody who thinks it has hung closes it. A bar that visibly moves
    /// and a host that visibly changes say the same thing the spinner was
    /// trying to: it is working, and it is nearly there.
    private var searchProgress: some View {
        VStack(alignment: .leading, spacing: Style.tight) {
            ProgressView(value: probe?.fraction ?? 0)
                .tint(Color.accentColor)

            HStack(spacing: Style.tight) {
                Text(probe.map { "Checking \($0.host)" } ?? "Checking your mailbox")
                    .font(Style.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let probe {
                    Text("\(probe.attempt) of \(probe.total)")
                        .font(Style.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: probe?.attempt)
    }

    /// Only reached when the guessing failed.
    private var imapServerStep: some View {
        AutoReplyStep(
            "Where is your mail?",
            serverNote ?? "Your provider's help pages list these as IMAP and SMTP settings."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                FieldBlock(label: "IMAP server", hint: "imap.yourcompany.com", text: $server.imapHost)
                    .textInputAutocapitalization(.never)

                FieldBlock(label: "Username", hint: "Usually your full email address", text: $server.username)
                    .textInputAutocapitalization(.never)

                FieldBlock(label: "Outgoing (SMTP) server", hint: "smtp.yourcompany.com", text: $server.smtpHost)
                    .textInputAutocapitalization(.never)

                VStack(alignment: .leading, spacing: Style.tight) {
                    Text("Outgoing port").font(Style.rowTitleStrong)
                    Picker("Outgoing port", selection: $server.smtpPort) {
                        Text("465 (SSL)").tag(465)
                        Text("587 (STARTTLS)").tag(587)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: server.smtpPort) { _, port in
                        server.smtpSecurity = port == 587 ? .startTLS : .tls
                    }
                }

                if isTesting { searchProgress }
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
        case .imapSignIn:    "Sign in"
        case .imapServer:    "Try again"
        case .naming:        "Continue"
        case .importScope:   "Bring it over"
        case .importing:     nil
        case .done:          firstRun ? "Start using Maily" : "Done"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .provider: provider != nil
        case .imapSignIn:
            imapAddress.contains("@") && !imapPassword.isEmpty && !isTesting
        case .imapServer:
            !server.imapHost.isEmpty && !server.username.isEmpty && !isTesting
        default: true
        }
    }

    private func advance() {
        switch step {
        case .googleConsent:
            Task { await connect() }
        case .imapSignIn:
            Task { await signInToIMAP(using: nil) }
        case .imapServer:
            Task { await signInToIMAP(using: server) }
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

    /// Signs in to an IMAP mailbox, guessing the server unless one is given.
    ///
    /// The order matters and is the opposite of what is obvious: nothing is
    /// saved until a server has actually accepted the password. An account
    /// record written first would leave a broken mailbox in the list every
    /// time somebody mistyped their password.
    private func signInToIMAP(using known: IMAPConfig?) async {
        isTesting = true
        defer { isTesting = false; probe = nil }

        let address = MailboxID.canonical(imapAddress)

        if mail.registry.holds(address) {
            failure = "\(address) is already here. Switch to it from Mailboxes."
            return
        }

        let outcome: IMAPProbe.Outcome
        if let known {
            probe = IMAPProbe.Progress(host: known.imapHost, attempt: 1, total: 1)
            outcome = await IMAPProbe.verify(known, password: imapPassword)
        } else {
            outcome = await IMAPProbe.discover(address: address, password: imapPassword) { step in
                Task { @MainActor in probe = step }
            }
        }

        switch outcome {
        case .ok(let success):
            await adopt(success, address: address)

        case .refused(_, let host):
            // A server answered and said no, which means one of two things
            // that look identical from here: the password is wrong, or this is
            // a real server that this mailbox is not on. Only the person can
            // tell, so the app names the door it knocked on instead of
            // deciding for them -- and the manual form is one tap away either
            // way.
            failure = """
            \(host) answered, but did not accept that username and password.

            If that is not your mail server, tap "Enter server settings myself" and put the right one in.
            """

        case .unreachable(let reason):
            // Nothing answered anywhere. This is the case the manual form is
            // for, prefilled with the best guess so far.
            server = known ?? MailServerGuess.first(for: address).config
            serverNote = reason
            if showsServerFields {
                failure = reason
            } else {
                withAnimation(.snappy(duration: 0.25)) {
                    showsServerFields = true
                    index += 1
                }
            }
        }
    }

    /// A verified mailbox becomes an account.
    private func adopt(_ success: IMAPProbe.Success, address: String) async {
        var config = success.config
        config.username = success.config.username

        let connected = MailAccount(
            provider: .imap,
            address: address,
            displayName: address,
            tint: mail.registry.nextTint,
            server: config
        )

        // Only now, and only because a server accepted it.
        Keychain.storeQuietly(imapPassword, .imapPassword, for: connected.id)
        Keychain.storeQuietly(imapPassword, .smtpPassword, for: connected.id)

        // Not kept in view state a moment longer than it has to be.
        imapPassword = ""

        await mail.adopt(connected)
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
