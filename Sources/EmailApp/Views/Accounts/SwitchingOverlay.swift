import SwiftUI
import UIKit

/// What a change of mailbox looks like.
///
/// Over the whole app rather than inside a screen: the switch can be started
/// from the inbox toolbar, from You, or from the mailbox list, and all three
/// should look the same. Sitting on `RootView` also puts it above the tab bar
/// and above anything presented.
///
/// The outgoing mailbox blurs rather than blanking. A screen that empties and
/// refills reads as a reload; one that softens and comes back reads as the
/// same app looking somewhere else.
struct SwitchingOverlay: View {
    @Environment(MailStore.self) private var mail

    var body: some View {
        ZStack {
            if mail.isSwitching, let account = mail.switchingTo {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    SenderAvatar(contact: account.contact, size: 64)
                        .overlay { Circle().strokeBorder(account.tint.color, lineWidth: 3) }
                        .transition(.scale(scale: 0.92).combined(with: .opacity))

                    VStack(spacing: 3) {
                        // Named, not "Switching accounts". They know they are
                        // switching; what they want confirmed is to what.
                        Text("Switching to")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(account.address)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 32)
                    }

                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mail.isSwitching)
        .onChange(of: mail.isSwitching) { _, switching in
            // Something under the fingers, since the screen is deliberately
            // doing very little.
            if switching {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .allowsHitTesting(mail.isSwitching)
    }
}

/// The compact switcher for the inbox toolbar.
///
/// The active account's face, where Gmail and Spark put it. Only appears with
/// more than one mailbox -- a switcher offering one thing is a control that
/// does nothing.
struct MailboxSwitcher: View {
    @Environment(MailStore.self) private var mail
    @Binding var isAdding: Bool
    @Binding var isManaging: Bool

    var body: some View {
        Menu {
            // Only what you can move to. The active mailbox is the face on
            // the button that opened this menu, so listing it again with a
            // tick beside it was saying twice what the avatar already said --
            // and it put an item in the menu that does nothing when tapped.
            ForEach(mail.registry.accounts.filter { $0.id != mail.account?.id }) { account in
                Button {
                    Task { await mail.activate(account) }
                } label: {
                    Label(account.title, systemImage: "arrow.left.arrow.right")
                }
            }

            Divider()
            Button { isAdding = true } label: { Label("Add account", systemImage: "plus") }
            Button { isManaging = true } label: { Label("Manage accounts", systemImage: "person.2") }
        } label: {
            if let account = mail.account {
                SenderAvatar(contact: account.contact, size: 26)
                    .overlay { Circle().strokeBorder(account.tint.color, lineWidth: 1.5) }
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Mailbox: \(mail.account?.title ?? "none")")
    }
}
