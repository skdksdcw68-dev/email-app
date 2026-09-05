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
    /// Which mailbox's page to push. Driven by state rather than a link,
    /// because a context menu item cannot be a `NavigationLink`.
    @State private var opening: MailboxID?

    private var registry: MailboxRegistry { mail.registry }

    var body: some View {
        List {
            // The one you are in, at the top, as a statement rather than a
            // choice.
            if let active = mail.account {
                Section {
                    currentCard(active)
                }
            }

            // And below it, only the ones you can move to.
            //
            // Telegram's shape, and Abel asked for it by name. The active
            // account was in this list with a tick beside it, which is a row
            // that cannot be tapped, sitting among rows whose whole purpose is
            // being tapped. Naming it above and listing the rest turns a list
            // of accounts into a list of destinations.
            Section {
                ForEach(registry.accounts.filter { $0.id != mail.account?.id }) { account in
                    row(account)
                }
                addRow
            } header: {
                if registry.hasSeveral {
                    Text("Switch to")
                }
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
        .listStyle(.insetGrouped)
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .sheet(isPresented: $isAdding) { AddMailboxFlow() }
        .navigationDestination(item: $opening) { MailboxDetailView(mailbox: $0) }
        .alert(item: $removing) { account in
            Alert(
                title: Text("Sign out of \(account.address)?"),
                // Named rather than "Gmail", which was wrong the moment a
                // mailbox could be somewhere else -- and the reassurance only
                // works if it names the place their mail actually is.
                message: Text("Its mail, read state, snoozes and drafts go from this phone, and Maily's access to it ends. Nothing on \(account.provider.inSentence) is touched."),
                primaryButton: .destructive(Text("Sign out")) { remove(account) },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Rows

    /// The mailbox you are in. Bigger, and it does not offer to switch to
    /// itself -- tapping it opens its settings, which is the only thing left
    /// to want from it.
    private func currentCard(_ account: MailAccount) -> some View {
        NavigationLink {
            MailboxDetailView(mailbox: account.id)
        } label: {
            HStack(spacing: 14) {
                MailboxAvatar(account: account, size: 52)
                    .overlay { Circle().strokeBorder(account.tint.color, lineWidth: 2) }

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(account.address)
                        .font(Style.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if account.needsAttention {
                        Label("Needs signing in again", systemImage: "exclamationmark.triangle.fill")
                            .font(Style.caption)
                            .foregroundStyle(Color.warning)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .contextMenu {
            Button(role: .destructive) { removing = account } label: {
                Label("Sign out of this mailbox", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    /// One mailbox you can move to. Never the active one -- that is drawn
    /// above, and a row you cannot switch to among rows that exist to be
    /// switched to is a row that has to explain itself.
    private func row(_ account: MailAccount) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await mail.activate(account) }
            } label: {
                HStack(spacing: 12) {
                    MailboxAvatar(account: account, size: 38)
                        .overlay {
                            Circle().strokeBorder(account.tint.color, lineWidth: 2)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title)
                            .font(Style.rowTitleStrong)
                            .foregroundStyle(.primary)
                        Text(account.address)
                            .font(Style.rowDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    trailing(account)
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
        // Both, deliberately.
        //
        // The swipe was already here and nothing said so, which is the trouble
        // with swipe as the only way to reach something: it is fast once you
        // know and invisible until then. Signing an account out is not a thing
        // anybody should have to discover by accident, so a long press offers
        // the same list in a form that can be looked for.
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { removing = account } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button { opening = account.id } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button {
                Task { await mail.activate(account) }
            } label: {
                Label("Switch to this mailbox", systemImage: "arrow.left.arrow.right")
            }

            Button { opening = account.id } label: {
                Label("Mailbox settings", systemImage: "gearshape")
            }

            Divider()

            Button(role: .destructive) { removing = account } label: {
                Label("Sign out of this mailbox", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder
    private func trailing(_ account: MailAccount) -> some View {
        // No tick for the active one any more -- it is not in this list.
        if account.needsAttention {
            // Amber, and never silence. An expired grant used to present as
            // an inbox that simply stopped filling.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color.warning)
        } else if account.isPaused {
            Text("Paused")
                .font(Style.rowDetail)
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
                        .font(Style.rowTitle)
                        .foregroundStyle(.primary)
                    // Outlook is still the row marked "Coming soon", so it does
                    // not get promised here.
                    Text("Gmail, or any other email address")
                        .font(Style.rowDetail)
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
