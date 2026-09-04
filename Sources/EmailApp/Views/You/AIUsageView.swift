import SwiftUI

/// What the app has asked the AI to do this month.
///
/// ⚠️ This used to open by saying Maily runs on the person's own key and the
/// bill arrives somewhere else. It does not. The key is in the project's
/// Supabase secrets and every call is spent on the operator's account -- see
/// the note in `AIUsage`.
///
/// So this is counts, not money, because counts are what the *phone* knows.
/// The real figure now exists on the server, priced from the provider's own
/// token counts (migration 0007), and this screen becomes the offline
/// fallback rather than the answer once there is a plan to count against.
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
