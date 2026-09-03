import SwiftUI

/// The answers given at sign-up, changeable afterwards.
///
/// Onboarding asks what somebody does, what matters in their inbox, how much
/// they want the assistant to take on and how they like replies to sound.
/// Those answers steer everything the AI does, and until now they were asked
/// once and never seen again -- which is a strange thing to do with the four
/// questions that decide how the app behaves. A person whose job changed had
/// no way to say so.
///
/// Nothing new is invented here. It is the same questions, the same options
/// and the same store; only the door is new.
struct PersonalizationView: View {
    @Environment(UserStore.self) private var user

    var body: some View {
        List {
            Section {
                Text("These are the answers you gave when you set Maily up. They steer what it treats as important and how it writes for you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            ForEach(user.questions) { question in
                Section {
                    ForEach(question.options) { option in
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                user.toggle(option, in: question)
                            }
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: option.symbol)
                                    .font(.footnote)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(isOn(option, question) ? AnyShapeStyle(Color.accentColor)
                                                                            : AnyShapeStyle(.secondary))
                                    .frame(width: 24)
                                Text(option.label)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                if isOn(option, question) {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(question.title)
                } footer: {
                    if let subtitle = question.subtitle {
                        Text(subtitle)
                    }
                }
            }

            Section {
                NavigationLink { WritingStyleView() } label: {
                    Label("Writing style", systemImage: "pencil.line").font(.subheadline)
                }
                NavigationLink { MemorySettingsView() } label: {
                    Label("What Maily remembers", systemImage: "brain").font(.subheadline)
                }
            } footer: {
                Text("The rest of what Maily knows about you lives in these two.")
            }
        }
        .navigationTitle("Personalization")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }

    private func isOn(_ option: OnboardingQuestion.Option, _ question: OnboardingQuestion) -> Bool {
        user.selections(for: question).contains(option.id)
    }
}
