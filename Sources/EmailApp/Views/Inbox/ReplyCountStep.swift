import SwiftUI
import UIKit

/// How many replies to write, laid out exactly like an onboarding question:
/// a grid of compact tiles, two to a row, one tap to choose. Same heights,
/// same corner radius, same tinted-fill-plus-border selected state -- a flow
/// that asks questions should look like the other flow that asks questions.
struct ReplyCountStep: View {
    let available: Int
    @Binding var selection: BulkReplyFlow.Selection
    let selectedCount: Int
    let onPickManually: () -> Void
    let onContinue: () -> Void

    @State private var showsNumberPad = false

    /// Every step, always shown. Ones the mailbox cannot satisfy are visibly
    /// disabled rather than missing: a grid that changes shape depending on
    /// how much mail you have is disorienting, and "why is 50 not there" is a
    /// worse question than "50 is greyed out because you have 38".
    private static let allPresets = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 100]

    private func isAvailable(_ number: Int) -> Bool { number <= available }

    private var isCustom: Bool {
        if case .count(let n) = selection { return !Self.allPresets.contains(n) && n > 0 }
        return false
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "How many replies?",
                subtitle: "\(available) \(available == 1 ? "email needs" : "emails need") a reply. Maily drafts the ones you pick, and nothing is sent yet."
            )

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Self.allPresets, id: \.self) { number in
                        tile(
                            number: "\(number)",
                            label: "replies",
                            isSelected: selection == .count(number),
                            isEnabled: isAvailable(number)
                        ) { selection = .count(number) }
                    }

                    tile(
                        symbol: "tray.full.fill",
                        label: "All",
                        detail: "\(available) emails",
                        isSelected: selection == .all
                    ) { selection = .all }

                    tile(
                        symbol: "number",
                        label: isCustom ? "\(selectedCount) replies" : "Custom",
                        detail: "my own number",
                        isSelected: isCustom
                    ) { showsNumberPad = true }

                    tile(
                        symbol: "hand.tap.fill",
                        label: "Choose",
                        detail: selection == .manual && selectedCount > 0
                            ? "\(selectedCount) picked"
                            : "one by one",
                        isSelected: selection == .manual
                    ) {
                        selection = .manual
                        onPickManually()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            PrimaryButton(
                title: selectedCount == 0 ? "Pick some emails" : "Continue with \(selectedCount)",
                isEnabled: selectedCount > 0,
                action: onContinue
            )
        }
        .navigationTitle("Reply with AI")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsNumberPad) {
            NumberPadSheet(maximum: available, current: selectedCount) { chosen in
                selection = .count(chosen)
            }
            // Small, centred, and nothing behind it moves.
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
    }

    /// One compact tile, in the onboarding question's visual language: a
    /// leading number or icon, a footnote label, tinted fill and border when
    /// selected.
    private func tile(
        number: String? = nil,
        symbol: String? = nil,
        label: String,
        detail: String? = nil,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { action() }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let number {
                        Text(number)
                            .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 32, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    }
            }
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Typing a number, in its own sheet.
///
/// Separate from the grid on purpose: a text field inside a scrolling list
/// means the keyboard shoves the whole layout around every time it appears,
/// which is what made that screen stutter.
struct NumberPadSheet: View {
    let maximum: Int
    let current: Int
    let onChoose: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var value: Int { min(Int(text) ?? 0, maximum) }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("How many?")
                    .font(.headline)
                Text("Up to \(maximum)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            TextField("0", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .focused($isFocused)
                .frame(maxWidth: 200)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                }
                .onChange(of: text) { _, entered in
                    // Digits only, clamped as it is typed. Asking for two
                    // hundred out of twelve means twelve.
                    let digits = entered.filter(\.isNumber)
                    if digits != entered { text = digits; return }
                    if let number = Int(digits), number > maximum { text = "\(maximum)" }
                }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Text("Clear")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(BouncyButtonStyle())

                Button {
                    onChoose(value)
                    dismiss()
                } label: {
                    Text("Use \(value)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().fill(value > 0 ? Color.accentColor : Color.secondary))
                }
                .buttonStyle(BouncyButtonStyle())
                .disabled(value == 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .keyboardDismissable()
        .onAppear {
            if current > 0 { text = "\(current)" }
            isFocused = true
        }
    }
}
