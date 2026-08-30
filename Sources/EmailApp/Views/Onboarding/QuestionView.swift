import SwiftUI
import UIKit

/// One screen for every onboarding question. The questions are data, so this
/// is the only question UI in the app -- adding or reordering questions never
/// touches SwiftUI.
struct QuestionView: View {
    let question: OnboardingQuestion

    @Environment(UserStore.self) private var user

    private var selected: Set<String> { user.selections(for: question) }

    /// Tiles scale with how many there are. Eight or fewer get room to breathe
    /// with the icon above the label; sixteen would turn that into a scroll
    /// marathon, so those go compact with the icon beside it.
    private var isCompact: Bool { question.options.count > 8 }

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
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = question.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(question.options) { option in
                OptionTile(
                    option: option,
                    isSelected: selected.contains(option.id),
                    isCompact: isCompact
                ) {
                    toggle(option)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var list: some View {
        VStack(spacing: 9) {
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
    let isCompact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isCompact {
                    HStack(alignment: .top, spacing: 9) {
                        icon(size: 15)
                        label
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        icon(size: 22)
                        label
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: isCompact ? 66 : 104, alignment: .topLeading)
            .background(background)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func icon(size: CGFloat) -> some View {
        Image(systemName: option.symbol)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: isCompact ? 19 : 26, alignment: .leading)
    }

    private var label: some View {
        Text(option.label)
            .font(isCompact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
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
            HStack(spacing: 13) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 24)

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
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview("Few options") {
    QuestionView(question: .role)
        .environment(UserStore(defaults: .previews, startAt: .question(0)))
}

#Preview("Many options") {
    QuestionView(question: .priorities)
        .environment(UserStore(defaults: .previews, startAt: .question(2)))
}

#Preview("List") {
    QuestionView(question: .autonomy)
        .environment(UserStore(defaults: .previews, startAt: .question(4)))
}
