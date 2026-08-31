import SwiftUI
import UIKit

/// The onboarding tone answers, as a list you can change later.
enum WritingTone: String, CaseIterable, Identifiable {
    case professional, warm, direct, thorough, casual

    var id: Self { self }

    var title: String {
        switch self {
        case .professional: "Professional"
        case .warm:         "Friendly"
        case .direct:       "Concise"
        case .thorough:     "Detailed"
        case .casual:       "Casual"
        }
    }

    /// Must match what UserStore.tonePreference produces, since that is what
    /// actually reaches the model.
    var instruction: String {
        switch self {
        case .professional: "formal and professional"
        case .warm:         "warm and friendly"
        case .direct:       "short and direct, no filler"
        case .thorough:     "detailed and thorough"
        case .casual:       "casual and relaxed"
        }
    }
}

/// What the AI is allowed to do, and what it costs.
struct AIPreferencesView: View {
    @State private var tagging = AppSettings.tagsIncomingMail
    @State private var summaries = AppSettings.writesSummaries

    var body: some View {
        List {
            Section {
                Toggle("Tag incoming mail", isOn: $tagging)
                    .onChange(of: tagging) { _, value in AppSettings.tagsIncomingMail = value }
            } footer: {
                Text("Off, Maily still sorts mail using rules on this device. Those are free and nothing leaves your phone.")
            }

            Section {
                Toggle("Summarise when I open a message", isOn: $summaries)
                    .onChange(of: summaries) { _, value in AppSettings.writesSummaries = value }
            } footer: {
                Text("Summaries are written when you open an email, so you only pay for what you read.")
            }

            Section {
                Label("Maily never sends without you", systemImage: "hand.raised.fill")
                    .font(.subheadline)
                Label("Only headers and the opening of a message are sent", systemImage: "lock.fill")
                    .font(.subheadline)
                Label("Results are cached, so nothing is paid for twice", systemImage: "arrow.clockwise")
                    .font(.subheadline)
            } header: {
                Text("How it works")
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }
}
