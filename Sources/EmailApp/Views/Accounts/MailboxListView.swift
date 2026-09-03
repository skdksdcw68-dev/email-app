import SwiftUI

/// Every mailbox, and which one you are in.
///
/// Tapping a row switches to it. The chevron opens its page. Two targets on
/// one row is a little unusual, and it is what the shape of the thing asks
/// for: switching is the common action by a wide margin, and burying it
/// behind a detail page would make the frequent thing the slower one.
struct MailboxListView: View {
    @Environment(MailStore.self) private var mail

    @State private var isAdding = false
    @State private var removing: MailAccount?

    private var registry: MailboxRegistry { mail.registry }

    var body: some View {
        List {
            Section {
                ForEach(registry.accounts) { account in
                    row(account)
                }
                addRow
            } header: {
                Text("Mailboxes")
            }

            if registry.hasSeveral {
                Section {
                    Picker("Opens on", selection: defaultBinding) {
                        Text("Last used").tag(nil as MailboxID?)
                        ForEach(registry.accounts) { account in
                            Text(account.title).tag(account.id as MailboxID?)
                        }
                    }
                } header: {
                    Text("Default")
                } footer: {
                    Text("Which mailbox Maily opens on.")
                }
            }
        }
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .sheet(isPresented: $isAdding) { AddMailboxFlow() }
        .alert(item: $removing) { account in
            Alert(
                title: Text("Remove \(account.address)?"),
                message: Text("Its mail, read state, snoozes and drafts go from this phone, and Maily's access to it ends. Nothing in Gmail is touched."),
                primaryButton: .destructive(Text("Remove")) { remove(account) },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Rows

    private func row(_ account: MailAccount) -> some View {
        let isActive = account.id == mail.account?.id

        return HStack(spacing: 12) {
            Button {
                guard !isActive else { return }
                Task { await mail.activate(account) }
            } label: {
                HStack(spacing: 12) {
                    SenderAvatar(contact: account.contact, size: 38)
                        .overlay {
                            Circle().strokeBorder(account.tint.color, lineWidth: 2)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(account.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    trailing(account, isActive: isActive)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink {
                MailboxDetailView(mailbox: account.id)
            } label: {
                EmptyView()
            }
            .frame(width: 12)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { removing = account } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func trailing(_ account: MailAccount, isActive: Bool) -> some View {
        if account.needsAttention {
            // Amber, and never silence. An expired grant used to present as
            // an inbox that simply stopped filling.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if isActive {
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        } else if account.isPaused {
            Text("Paused")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var addRow: some View {
        Button {
            isAdding = true
        } label: {
            HStack(spacing: 12) {
                // The blue circle is the affordance. A plain row saying "Add
                // account" reads as another destination among the mailboxes
                // rather than the thing that makes a new one.
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.blue))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Add account")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text("Gmail, Outlook, or your own email")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Acting

    private var defaultBinding: Binding<MailboxID?> {
        Binding(
            get: {
                if case .fixed(let id) = registry.defaultPolicy { return id }
                return nil
            },
            set: { registry.setDefaultPolicy($0.map { .fixed($0) } ?? .lastUsed) }
        )
    }

    private func remove(_ account: MailAccount) {
        if account.id == mail.account?.id {
            mail.disconnect()
        } else {
            registry.forget(account.id)
        }
    }
}

#Preview {
    NavigationStack { MailboxListView() }
        .environment(MailStore.connected())
}
