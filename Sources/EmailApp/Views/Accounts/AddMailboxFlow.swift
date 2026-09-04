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
    @State private var isTesting = false
    /// What the IMAP server said about itself, kept between the two checks.
    @State private var verified: IMAPProbe.Success?
    @State private var usesSeparateSMTPPassword = false
    @State private var smtpPassword = ""
    /// Sending failed. Not fatal -- receiving already works.
    @State private var sendingProblem: String?

    // MARK: - The step graph

    enum Step: String, CaseIterable {
        case provider
        case googleConsent
        case imapSignIn
        case imapIncoming
        case imapOutgoing
        case naming
        case importScope
        case importing
        case done

        /// Steps that own the whole screen rather than sitting above a form.
        var isFullHeight: Bool { self == .importing || self == .done }
    }

    private var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            // Nothing to name when there is only one, and nothing to tell
            // apart with a colour either.
            case .naming: !firstRun
            case .googleConsent: provider != .imap
            case .imapSignIn, .imapIncoming, .imapOutgoing: provider == .imap
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
                if !step.isFullHeight && step != .provider {
                    ProgressView(value: progress)
                        .tint(Color.accentColor)
                        .padding(.horizontal, Style.gutter)
                        .padding(.bottom, 10)
                }

                // Two layouts, because there are two kinds of step here.
                //
                // A form is a column that starts at the top and grows down,
                // and a heading above it belongs at the top left. A screen
                // whose whole job is one ring, or one line saying it worked,
                // is not that -- and putting it in the form layout left the
                // ring high on the screen with a third of the phone empty
                // underneath, and the title jammed against the sheet's own
                // rounded corner with nothing above it.
                if step.isFullHeight {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, Style.gutter)
                } else {
                    ScrollView {
                        content
                            .padding(.horizontal, Style.gutter)
                            .padding(.bottom, Style.tight)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }

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
            // Sending failing is not the same as the mailbox failing, and it
            // should not throw away a connection that already works. Reading
            // mail is most of what this app is for; the outgoing settings can
            // be fixed later from the mailbox's own page.
            .alert("Sending didn't work", isPresented: .constant(sendingProblem != nil)) {
                Button("Add it anyway") {
                    sendingProblem = nil
                    Task { await adoptVerifiedMailbox() }
                }
                Button("Fix the settings", role: .cancel) { sendingProblem = nil }
            } message: {
                Text((sendingProblem ?? "") + "\n\nReceiving already works. You can add the mailbox now and sort sending out later, but you will not be able to send from it until you do.")
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
        case .imapSignIn:   imapSignInStep
        case .imapIncoming: imapIncomingStep
        case .imapOutgoing: imapOutgoingStep
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
            "Add your email address",
            "Business email, your own domain, or most other providers."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                FieldBlock(label: "Email address", hint: "you@yourcompany.com", text: $imapAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)

                if let warning = MailServerGuess.first(for: imapAddress).warning,
                   imapAddress.contains("@") {
                    Label(warning, systemImage: "info.circle")
                        .font(Style.rowDetail)
                        .foregroundStyle(Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The server, asked for rather than hunted for.
    ///
    /// This screen replaced a search that tried up to eight hosts in turn,
    /// thirty seconds apiece. It was clever and it was wrong: slow when it
    /// worked, and when it failed it could only say "a server refused you"
    /// without being able to say which -- because it had picked the server.
    ///
    /// Gmail's own app just asks. So does this now. The fields arrive
    /// prefilled from the domain, so for most people it is still one tap; for
    /// everybody else it is the four things their host's help page lists,
    /// under the same names their host uses.
    private var imapIncomingStep: some View {
        AutoReplyStep(
            "Incoming server settings",
            "Your provider lists these as IMAP settings."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                FieldBlock(label: "Username", hint: "Usually your full email address", text: $server.username)
                    .textInputAutocapitalization(.never)

                passwordField("Password", text: $imapPassword)

                FieldBlock(label: "IMAP server", hint: "imap.yourcompany.com", text: $server.imapHost)
                    .textInputAutocapitalization(.never)

                portField("Port", port: $server.imapPort)

                securityPicker("Security type", security: $server.imapSecurity, port: $server.imapPort)

                connecting(to: server.imapHost)
                keychainNote
            }
        }
    }

    /// Reached only once the incoming settings are known to work.
    ///
    /// Two pages, checked one at a time, because they are two different
    /// servers and can want two different answers -- plenty of hosts issue a
    /// separate password for sending. One long form checked at the end can
    /// only say "something is wrong" and leave you to work out which half.
    private var imapOutgoingStep: some View {
        AutoReplyStep(
            "Outgoing server settings",
            "Your provider lists these as SMTP settings."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                Label("Receiving works", systemImage: "checkmark.circle.fill")
                    .font(Style.rowDetail)
                    .foregroundStyle(Color.ok)

                FieldBlock(label: "SMTP server", hint: "smtp.yourcompany.com", text: $server.smtpHost)
                    .textInputAutocapitalization(.never)

                portField("Port", port: $server.smtpPort)

                securityPicker("Security type", security: $server.smtpSecurity, port: $server.smtpPort)

                Toggle("Sending needs a different password", isOn: $usesSeparateSMTPPassword)
                    .font(Style.rowTitle)

                if usesSeparateSMTPPassword {
                    passwordField("Sending password", text: $smtpPassword)
                }

                connecting(to: server.smtpHost)
            }
        }
    }

    private func passwordField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Style.tight) {
            Text(label).font(Style.rowTitleStrong)
            SecureField("", text: text)
                .textContentType(.password)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .cardBackground()
        }
    }

    @ViewBuilder
    private func connecting(to host: String) -> some View {
        if isTesting {
            HStack(spacing: Style.tight) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(host)…")
                    .font(Style.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var keychainNote: some View {
        Text("Your password is kept in this phone's Keychain and used only to reach your mail server. It is not sent anywhere else.")
            .font(Style.rowDetail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func portField(_ label: String, port: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: Style.tight) {
            Text(label).font(Style.rowTitleStrong)
            TextField("", value: port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .cardBackground()
        }
    }

    /// The port and the encryption are two ways of saying one thing, and
    /// people get them out of step. Changing either moves the other to the
    /// pairing that actually exists.
    private func securityPicker(
        _ label: String,
        security: Binding<TransportSecurity>,
        port: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: Style.tight) {
            Text(label).font(Style.rowTitleStrong)
            Picker(label, selection: security) {
                Text("SSL/TLS").tag(TransportSecurity.tls)
                Text("STARTTLS").tag(TransportSecurity.startTLS)
            }
            .pickerStyle(.segmented)
            .onChange(of: security.wrappedValue) { _, choice in
                if port.wrappedValue == 993 || port.wrappedValue == 143 {
                    port.wrappedValue = choice == .tls ? 993 : 143
                } else if port.wrappedValue == 465 || port.wrappedValue == 587 {
                    port.wrappedValue = choice == .tls ? 465 : 587
                }
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

    /// No heading of its own.
    ///
    /// `ImportingMailView` already says what is happening, and says it in the
    /// middle of the screen where the ring is. "Bringing your mail over" above
    /// "Looking through your mailbox" was the same sentence twice, one of them
    /// pinned to the top left, and it pushed the ring up out of the middle.
    private var importingStep: some View {
        ImportingMailView(progress: mail.importProgress, canLeave: !firstRun)
    }

    private var doneStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.ok)
                .padding(.bottom, 24)

            Text(mail.account.map { "\($0.address) is ready" } ?? "Ready")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                // The address is the long part and it must not be cut in half
                // by the edge of the phone.
                .fixedSize(horizontal: false, vertical: true)

            Text("You can switch between mailboxes from the inbox, or from You.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Style.tight)

            Spacer()
        }
        .frame(maxWidth: .infinity)
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
        case .imapSignIn:    "Next"
        case .imapIncoming:  "Check receiving"
        case .imapOutgoing:  "Check sending"
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
            imapAddress.contains("@")
        case .imapIncoming:
            !server.imapHost.isEmpty && !server.username.isEmpty
                && !imapPassword.isEmpty && !isTesting
        case .imapOutgoing:
            !server.smtpHost.isEmpty && !isTesting
                && (!usesSeparateSMTPPassword || !smtpPassword.isEmpty)
        default: true
        }
    }

    private func advance() {
        switch step {
        case .googleConsent:
            Task { await connect() }
        case .imapSignIn:
            // Prefilled from the domain, so most people read four correct
            // fields and press the button. Nothing is dialled yet.
            server = MailServerGuess.first(for: imapAddress).config
            withAnimation(.snappy(duration: 0.25)) { index += 1 }
        case .imapIncoming:
            Task { await checkReceiving() }
        case .imapOutgoing:
            Task { await checkSending() }
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

    /// Half one: can we read this mailbox?
    ///
    /// One attempt against the server that was actually typed in. It used to
    /// search up to eight hosts in turn -- slow, and when it failed it could
    /// not say *which* server refused, because the app had chosen it rather
    /// than the person.
    private func checkReceiving() async {
        isTesting = true
        defer { isTesting = false }

        let address = MailboxID.canonical(imapAddress)

        if mail.registry.holds(address) {
            failure = "\(address) is already here. Switch to it from Mailboxes."
            return
        }

        switch await IMAPProbe.verify(server, password: imapPassword) {
        case .ok(let success):
            // Keep what the server said about itself -- the folder names in
            // particular, which are what tell Sent from Drafts later.
            verified = success
            withAnimation(.snappy(duration: 0.25)) { index += 1 }

        case .refused(let reason, _), .unreachable(let reason):
            failure = reason
        }
    }

    /// Half two: can we send from it?
    ///
    /// Checked separately because it is a different server, and often a
    /// different password. Failing here does not undo half one -- receiving
    /// still works, and the mailbox is worth having either way, so this offers
    /// to carry on rather than throwing the whole thing away.
    private func checkSending() async {
        isTesting = true
        defer { isTesting = false }

        let password = usesSeparateSMTPPassword ? smtpPassword : imapPassword

        switch await SMTPProbe.verify(server, username: server.username, password: password) {
        case .ok:
            await adoptVerifiedMailbox()
        case .failed(let reason):
            sendingProblem = reason
        }
    }

    /// The mailbox, once it is known to work.
    private func adoptVerifiedMailbox() async {
        guard let verified else { return }
        await adopt(verified, address: MailboxID.canonical(imapAddress))
    }

    /// A verified mailbox becomes an account.
    private func adopt(_ success: IMAPProbe.Success, address: String) async {
        // `server` rather than `success.config`: the outgoing half was edited
        // on the second screen, after the first check captured it.
        var config = server
        config.imapHost = success.config.imapHost
        config.imapPort = success.config.imapPort
        config.imapSecurity = success.config.imapSecurity

        let connected = MailAccount(
            provider: .imap,
            address: address,
            displayName: address,
            tint: mail.registry.nextTint,
            server: config
        )

        // Only now, and only because a server accepted them.
        Keychain.storeQuietly(imapPassword, .imapPassword, for: connected.id)
        Keychain.storeQuietly(
            usesSeparateSMTPPassword ? smtpPassword : imapPassword,
            .smtpPassword,
            for: connected.id
        )

        // Not kept in view state a moment longer than it has to be.
        imapPassword = ""
        smtpPassword = ""

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
