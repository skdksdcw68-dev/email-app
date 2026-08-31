import SwiftUI
import UIKit

/// How many replies to write, laid out like an onboarding question: a grid of
/// tiles, two to a row, one tap to choose.
///
/// The previous version was a column of full-width cards with a text field
/// living inside one of them, which meant the keyboard appeared and the whole
/// list relaid out under it on every keystroke. Typing a number belongs in its
/// own small sheet, centred, and nothing behind it moves.
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

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "How many replies?",
                subtitle: "\(available) \(available == 1 ? "email needs" : "emails need") a reply. Maily drafts the ones you pick, and nothing is sent yet."
            )

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Self.allPresets, id: \.self) { number in
                        tile(
                            title: "\(number)",
                            detail: "replies",
                            isSelected: selection == .count(number),
                            isEnabled: isAvailable(number)
                        ) { selection = .count(number) }
                    }

                    tile(
                        title: "All",
                        detail: "\(available) emails",
                        symbol: "tray.full.fill",
                        isSelected: selection == .all
                    ) { selection = .all }

                    tile(
                        title: isCustom ? "\(selectedCount)" : "Custom",
                        detail: "my own number",
                        symbol: "number",
                        isSelected: isCustom
                    ) { showsNumberPad = true }

                    tile(
                        title: "Choose",
                        detail: selection == .manual && selectedCount > 0
                            ? "\(selectedCount) picked"
                            : "one by one",
                        symbol: "hand.tap.fill",
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

    private func tile(
        title: String,
        detail: String,
        symbol: String? = nil,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                        .padding(.bottom, 2)
                }
                Text(title)
                    .font(symbol == nil
                          ? .system(size: 28, weight: .bold, design: .rounded)
                          : .headline)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Color.accentColor)
                          : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)))
            }
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
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
