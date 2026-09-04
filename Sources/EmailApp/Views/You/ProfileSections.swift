import SwiftUI
import UIKit

/// The onboarding tone answers, as a list you can change later.
///
/// ⚠️ `matchMe` was missing, and it is the **default** -- `tonePreference`
/// falls through to "match how I already write" for anything it does not
/// recognise, and that is what somebody who never answered the question has.
/// So the one tone most people were actually on was the one tone this screen
/// could not show as selected, and picking anything else was a one-way door.
enum WritingTone: String, CaseIterable, Identifiable {
    case matchMe = "match_me"
    case professional, warm, direct, thorough, casual, confident, warmBrief = "warm_brief"

    var id: Self { self }

    var title: String {
        switch self {
        case .matchMe:      "Match how I write"
        case .professional: "Professional"
        case .warm:         "Friendly"
        case .direct:       "Concise"
        case .thorough:     "Detailed"
        case .casual:       "Casual"
        case .confident:    "Confident"
        case .warmBrief:    "Warm but brief"
        }
    }

    /// The one line under it, because "Detailed" and "Thorough" are the same
    /// word to most people until they see what each does.
    var detail: String {
        switch self {
        case .matchMe:      "Copies your own voice from mail you have sent"
        case .professional: "Formal, complete sentences, no contractions"
        case .warm:         "Friendly and personal, still businesslike"
        case .direct:       "Says the thing and stops"
        case .thorough:     "Covers everything, nothing left implied"
        case .casual:       "Relaxed, the way you would write to a friend"
        case .confident:    "Decisive. States rather than suggests"
        case .warmBrief:    "Kind opening, then straight to the point"
        }
    }

    /// Must match what `UserStore.tonePreference` produces, since that is what
    /// actually reaches the model.
    var instruction: String {
        switch self {
        case .matchMe:      "match how I already write"
        case .professional: "formal and professional"
        case .warm:         "warm and friendly"
        case .direct:       "short and direct, no filler"
        case .thorough:     "detailed and thorough"
        case .casual:       "casual and relaxed"
        case .confident:    "confident and decisive, state rather than suggest"
        case .warmBrief:    "warm in the opening line, then brief and direct"
        }
    }
}

/// What the AI is allowed to do on its own.
///
/// 🔴 **The one home for these two switches.** They were on three screens --
/// here, on Usage, and on AI & Automation -- and the same setting was called
/// "Tag incoming mail" on one and "Read incoming mail" on the other two. Three
/// copies of a switch is three chances for somebody to turn a thing off and
/// find it apparently still on somewhere else.
///
/// The other two now link here rather than drawing their own.
struct AIPreferencesView: View {
    @State private var tagging = AppSettings.tagsIncomingMail
    @State private var summaries = AppSettings.writesSummaries

    var body: some View {
        List {
            Section {
                // "Read", not "Tag". Tagging is what it does with what it
                // read, and somebody deciding whether to allow this cares
                // about the reading.
                Toggle("Read incoming mail", isOn: $tagging)
                    .onChange(of: tagging) { _, value in AppSettings.tagsIncomingMail = value }
            } footer: {
                Text("Lets Maily sort and label mail as it arrives. Off, it still sorts using rules on this phone — those are free and nothing leaves your device.")
            }

            Section {
                Toggle("Summarise when I open a message", isOn: $summaries)
                    .onChange(of: summaries) { _, value in AppSettings.writesSummaries = value }
            } footer: {
                Text("Written when you open an email, so you only pay for what you actually read.")
            }

            Section {
                Label("Maily never sends without you", systemImage: "hand.raised.fill")
                    .font(Style.rowTitle)
                Label("Only headers and the opening of a message are sent", systemImage: "lock.fill")
                    .font(Style.rowTitle)
                Label("Results are cached, so nothing is paid for twice", systemImage: "arrow.clockwise")
                    .font(Style.rowTitle)
            } header: {
                Text("How it works")
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }
}
