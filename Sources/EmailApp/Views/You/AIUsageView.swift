import SwiftUI

/// What the app has asked the AI to do this month.
///
/// Maily runs on the person's own key, so the bill arrives somewhere else and
/// the app is normally the last place to know. That is how it goes wrong:
/// the credit runs out, every AI feature stops at once, and nothing in the
/// app says why -- it just looks broken.
///
/// So this is counts, not money. The app cannot see a bill and inventing a
/// number would be worse than none. What it can honestly say is what it asked
/// for and what each ask was for, which is the sentence that explains the
/// figure on the website.
struct AIUsageView: View {
    @Environment(MailStore.self) private var mail

    @State private var isConfirmingReset = false

    private var used: [(kind: AIUsage.Kind, count: Int)] { AIUsage.used }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(AIUsage.total)")
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    Text(AIUsage.total == 1 ? "AI request in \(AIUsage.monthName)" : "AI requests in \(AIUsage.monthName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
            }

            if used.isEmpty {
                Section {
                    Text("Nothing yet this month.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(used, id: \.kind) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.kind.symbol)
                                .font(.footnote)
                                .foregroundStyle(row.kind.isExpensive ? Color.orange : Color.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.kind.title)
                                    .font(.subheadline.weight(.medium))
                                Text(row.kind.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text("\(row.count)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("What it was for")
                } footer: {
                    // The honest hint. A question costs many times what a
                    // classified email costs, and somebody wondering where
                    // their credit went cannot tell that from a raw count.
                    Text("The ones in orange are the expensive kind: each uses the bigger model and reads more of your mail. Reading is the cheap one, even though there is a lot of it.")
                }
            }

            // The switches themselves live on Preferences, and only there.
            // They were drawn here too, and on AI & Automation -- three copies
            // of the same two settings, two of them under a different name.
            Section {
                NavigationLink { AIPreferencesView() } label: {
                    Text("Turn things down").font(Style.rowTitle)
                }
            } footer: {
                Text("Reading is what runs on every message that arrives, so it is the one that adds up.")
            }

            Section {
                Button("Start this month over", role: .destructive) {
                    isConfirmingReset = true
                }
            } footer: {
                // 🔴 What used to be here was false, and it had been false for
                // as long as the app has been deployed:
                //
                //   "Maily runs on your own API key, so what you spend is
                //    between you and OpenAI."
                //
                // Nobody's key is on their phone. The key lives in the
                // project's Supabase secrets, so every one of these calls has
                // been spent on the operator's account. Saying otherwise was
                // not a rounding error in the copy -- it told people the one
                // thing that would stop them worrying about a number that was
                // actually somebody else's bill.
                //
                // The link to platform.openai.com went with it. Once these
                // calls are paid for through the App Store, a button pointing
                // at an outside billing page inside a paid feature is exactly
                // what guideline 3.1.1 is about.
                Text("These counts are kept on this phone. Reading is what runs on every message that arrives; questions and drafts are the expensive kind.")
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .alert("Start the count over?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { AIUsage.reset() }
        } message: {
            Text("Only the counts on this screen. Nothing about your mail or your bill changes.")
        }
    }
}

/// The things Maily does without being asked each time.
///
/// Only what actually runs. An automations screen listing a weekly summary
/// that nothing generates would be a promise the app does not keep, and this
/// is exactly the screen where people go looking for the switch that stops
/// something -- so everything here has to be real.
struct AutomationsView: View {
    @Environment(MailStore.self) private var mail
    @Environment(AutoReplyStore.self) private var autoReply

    var body: some View {
        List {
            Section {
                row("Sorting new mail", "tray.full.fill",
                    AppSettings.tagsIncomingMail ? "On" : "Off",
                    isOn: AppSettings.tagsIncomingMail)
                row("Following up", "clock.arrow.circlepath",
                    "\(mail.followUps.count) being watched", isOn: true)
                row("Auto-Reply", "arrowshape.turn.up.left.2.fill",
                    autoReply.config.isRunning
                        ? (autoReply.config.mode == .send ? "Sending" : "Writing drafts")
                        : "Off",
                    isOn: autoReply.config.isRunning)
            } header: {
                Text("Running")
            } footer: {
                Text("Everything Maily does on its own is here. Sorting is changed in AI preferences; follow-ups and Auto-Reply have their own screens.")
            }

            Section {
                NavigationLink { AIAutomationSettingsView() } label: {
                    Label("AI preferences", systemImage: "sparkles").font(.subheadline)
                }
                NavigationLink { AutoReplyView() } label: {
                    Label("Auto-Reply", systemImage: "arrowshape.turn.up.left.2.fill").font(.subheadline)
                }
            }
        }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }

    private func row(_ title: String, _ symbol: String, _ state: String, isOn: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 24)
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            Text(state)
                .font(.caption)
                .foregroundStyle(isOn ? Color.green : Color.secondary)
        }
        .padding(.vertical, 2)
    }
}
