import SwiftUI
import UIKit

/// One screen for every onboarding question. The questions are data, so this
/// is the only question UI in the app -- adding or reordering questions never
/// touches SwiftUI.
struct QuestionView: View {
    let question: OnboardingQuestion

    @Environment(UserStore.self) private var user

    private var selected: Set<String> { user.selections(for: question) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                switch question.layout {
                case .grid: grid
                case .list: list
                }
            }
            .scrollIndicators(.hidden)

            Button {
                user.next()
            } label: {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!user.canContinue(from: question))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = user.questionProgress {
                ProgressView(value: progress)
                    .tint(Color.accentColor)
                    .padding(.bottom, 4)
            }

            Text(question.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = question.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(question.options) { option in
                OptionTile(option: option, isSelected: selected.contains(option.id)) {
                    toggle(option)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(question.options) { option in
                OptionRow(option: option, isSelected: selected.contains(option.id)) {
                    toggle(option)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func toggle(_ option: OnboardingQuestion.Option) {
        withAnimation(.snappy(duration: 0.18)) {
            user.toggle(option, in: question)
        }
    }
}

// MARK: - Option chrome

private struct OptionTile: View {
    let option: OnboardingQuestion.Option
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                Text(option.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: option.symbol == nil ? 56 : 92, alignment: .topLeading)
            .padding(12)
            .background(background)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
    }
}

private struct OptionRow: View {
    let option: OnboardingQuestion.Option
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(option.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview("Grid") {
    QuestionView(question: .role)
        .environment(UserStore(defaults: .previews, startAt: .question(0)))
}

#Preview("List") {
    QuestionView(question: .autonomy)
        .environment(UserStore(defaults: .previews, startAt: .question(4)))
}
