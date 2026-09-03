import SwiftUI
import UIKit

/// The control centre: who you are, and the handful of things worth checking
/// on rather than configuring.
///
/// Six rows and a picker. Everything here either carries a live number or is
/// touched often enough to earn a place; everything else is behind Settings,
/// and nothing appears in both. A row repeated in two screens is a row
/// somebody has to decide about twice.
///
/// Labels are one word wherever a word will do, and what a row *is* sits on
/// the right rather than in a sentence underneath. A settings list reads
/// down the left edge, so the left edge should be short.
struct YouView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail
    @Environment(AutoReplyStore.self) private var autoReply
    @Environment(AutoReplyQueue.self) private var autoReplyQueue

    @State private var isEditingProfile = false
    @State private var appearance = AppSettings.appearance

    var body: some View {
        NavigationStack {
            List {
                Section { header.listRowSeparator(.hidden) }

                Section {
                    SettingsRow("Mailbox", "envelope",
                                value: mail.account?.email ?? "None") {
                        GmailAccountsView()
                    }
                    SettingsRow("Usage", "chart.bar",
                                value: AIUsage.total == 0 ? "None" : "\(AIUsage.total)") {
                        AIUsageView()
                    }
                    SettingsRow("Auto-Reply", "arrowshape.turn.up.left",
                                value: autoReplyValue, badge: autoReplyQueue.waiting.count) {
                        AutoReplyView()
                    }
                }

                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(width: 26)
                        Text("Appearance").font(.subheadline)
                        Spacer(minLength: 12)
                        Picker("", selection: $appearance) {
                            ForEach(AppSettings.Appearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: appearance) { _, value in
                            AppSettings.appearance = value
                            NotificationCenter.default.post(name: .appearanceChanged, object: nil)
                        }
                    }
                    .padding(.vertical, 1)
                }

                Section {
                    SettingsRow("Settings", "gearshape") { AppSettingsView() }
                }
            }
            .navigationTitle("You")
            .sheet(isPresented: $isEditingProfile) { EditProfileView() }
        }
    }

    // MARK: - Header

    /// The avatar carries the way in to editing, the way the apps people
    /// already use put it there. A separate "Edit profile" row underneath was
    /// a row spent on something the picture already implies.
    private var header: some View {
        VStack(spacing: 10) {
            Button { isEditingProfile = true } label: {
                SenderAvatar(
                    contact: Contact(
                        name: user.account?.displayName ?? "You",
                        address: user.account?.email ?? ""
                    ),
                    size: 76
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit profile")

            VStack(spacing: 2) {
                Text(user.account?.displayName ?? "You")
                    .font(.headline)
                if let occupation = user.account?.occupation, !occupation.isEmpty {
                    Text(occupation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var autoReplyValue: String {
        let config = autoReply.config
        guard config.isSetUp else { return "Off" }
        guard config.isOn else { return "Paused" }
        return config.mode == .send ? "Sending" : "Drafting"
    }
}

/// One row: an icon, a word, and what it is set to.
///
/// The value on the right is the point. "Appearance — System" tells somebody
/// what they came to find out without opening anything, where a sentence
/// underneath the label only tells them what the label already said.
struct SettingsRow<Destination: View>: View {
    let title: String
    let symbol: String
    var value: String?
    var badge: Int = 0
    @ViewBuilder let destination: Destination

    init(
        _ title: String,
        _ symbol: String,
        value: String? = nil,
        badge: Int = 0,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.badge = badge
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 26)
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 12)
                if badge > 0 {
                    WaitingBadge(count: badge)
                } else if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

#Preview {
    YouView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(AutoReplyStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply.json")))
        .environment(AutoReplyQueue(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply-queue.json")))
}
