import SwiftUI

/// One mailbox: what it is, what Maily may do with it, and how to be rid of it.
///
/// Reads its account out of the registry by id rather than holding a copy, so
/// renaming it or signing in again updates the screen you are looking at.
struct MailboxDetailView: View {
    let mailbox: MailboxID

    @Environment(MailStore.self) private var mail
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var isRefreshing = false
    @State private var isRemoving = false
    @State private var archiveSize = "—"

    private var account: MailAccount? { mail.registry.account(mailbox) }
    private var isActive: Bool { mailbox == mail.account?.id }

    var body: some View {
        List {
            if let account {
                header(account)
                naming(account)
                status(account)
                permissions(account)
                notifications(account)
                danger(account)
            } else {
                // Removed from another screen while this one was open.
                ContentUnavailableView("Mailbox removed", systemImage: "envelope.badge.shield.half.filled")
            }
        }
        .navigationTitle(account?.title ?? "Mailbox")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
        .hidesTabBar()
        .onAppear { nickname = account?.nickname ?? "" }
        .task { archiveSize = await MessageArchive.formattedSize(mailbox: mailbox) }
        .alert("Remove this mailbox?", isPresented: $isRemoving) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("Its mail, read state, snoozes and drafts go from this phone, and Maily's access to it ends. Nothing in Gmail is touched.")
        }
    }

    // MARK: - Sections

    private func header(_ account: MailAccount) -> some View {
        Section {
            HStack(spacing: 14) {
                MailboxAvatar(account: account, size: 56)
                    .overlay { Circle().strokeBorder(account.tint.color, lineWidth: 2) }

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.title3.weight(.bold))
                    Text(account.address)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(account.provider.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)

            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                Button("Switch to this mailbox") {
                    Task {
                        await mail.activate(account)
                        dismiss()
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func naming(_ account: MailAccount) -> some View {
        Section {
            TextField("Work", text: $nickname)
                .font(.subheadline)
                .onSubmit(saveName)
                .onChange(of: nickname) { _, _ in saveName() }

            HStack(spacing: 12) {
                ForEach(MailboxTint.allCases, id: \.self) { swatch in
                    Button {
                        mail.registry.update(mailbox) { $0.tint = swatch }
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 28, height: 28)
                            .overlay {
                                if account.tint == swatch {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Name and colour")
        } footer: {
            Text("Two accounts with the same name are told apart by these.")
        }
    }

    @ViewBuilder
    private func status(_ account: MailAccount) -> some View {
        Section {
            LabeledContent("Connection", value: connectionText(account))
            if isActive {
                LabeledContent("Messages held", value: "\(mail.messages.count)")
            }
            LabeledContent("Offline copy", value: archiveSize)
            LabeledContent("Brought over", value: account.importWindow.title)

            if isActive {
                Button {
                    Task {
                        isRefreshing = true
                        await mail.refresh()
                        isRefreshing = false
                    }
                } label: {
                    HStack {
                        Text(isRefreshing ? "Syncing…" : "Sync now")
                        Spacer()
                        if isRefreshing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isRefreshing)
            }
        } header: {
            Text("Status")
        }
    }

    private func permissions(_ account: MailAccount) -> some View {
        Section {
            Label("Read your mail", systemImage: "envelope.open")
            Label("Create drafts and send", systemImage: "paperplane")
        } header: {
            Text("What Maily can do")
        } footer: {
            // Kept word for word from the old accounts screen. It is the
            // reason archive and delete do not stick in Gmail, and it belongs
            // on the mailbox it is true of.
            Text("Maily cannot archive, delete or star mail. Doing that needs a further Gmail permission this app deliberately does not ask for.")
        }
    }

    private func notifications(_ account: MailAccount) -> some View {
        Section {
            Toggle("Notify me", isOn: Binding(
                get: { account.notifies },
                set: { on in mail.registry.update(mailbox) { $0.notifies = on } }
            ))
            .font(.subheadline)
        } footer: {
            Text(account.canPush
                 ? "New mail from this account wakes the phone."
                 : "This provider cannot push, so Maily checks when it gets the chance.")
        }
    }

    @ViewBuilder
    private func danger(_ account: MailAccount) -> some View {
        if case .needsReauth(let reason) = account.state {
            Section {
                Button("Sign in again") {
                    Task { await mail.connect() }
                }
                .font(.subheadline.weight(.semibold))
            } header: {
                Text("Needs attention")
            } footer: {
                Text(reason)
            }
        }

        Section {
            Button("Remove mailbox", role: .destructive) { isRemoving = true }
        }
    }

    // MARK: - Acting

    private func connectionText(_ account: MailAccount) -> String {
        switch account.state {
        case .ok: isActive && mail.connectionError != nil ? "Problem" : "Connected"
        case .needsReauth: "Sign in again"
        case .paused: "Paused"
        }
    }

    private func saveName() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        mail.registry.update(mailbox) { $0.nickname = trimmed.isEmpty ? nil : trimmed }
    }

    private func remove() {
        if isActive {
            mail.disconnect()
        } else {
            mail.registry.forget(mailbox)
        }
        dismiss()
    }
}
