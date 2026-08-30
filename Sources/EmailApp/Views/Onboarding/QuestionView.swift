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
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = user.questionProgress {
                ProgressView(value: progress)
                    .tint(Color.accentColor)
                    .padding(.bottom, 2)
            }

            Text(question.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = question.subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
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
        VStack(spacing: 7) {
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

/// Compact on purpose: some questions offer sixteen of these, so a tall tile
/// turns the screen into a scroll marathon.
private struct OptionTile: View {
    let option: OnboardingQuestion.Option
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: option.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 18, alignment: .leading)

                Text(option.label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .background(background)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
    }
}

private struct OptionRow: View {
    let option: OnboardingQuestion.Option
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: option.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 22)

                Text(option.label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview("Grid") {
    QuestionView(question: .priorities)
        .environment(UserStore(defaults: .previews, startAt: .question(2)))
}

#Preview("List") {
    QuestionView(question: .autonomy)
        .environment(UserStore(defaults: .previews, startAt: .question(4)))
}
