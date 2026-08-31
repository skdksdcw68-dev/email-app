import SwiftUI
import UIKit

// The individual screens and controls of the bulk reply flow, kept out of the
// flow file so that one stays readable as a description of the sequence.

/// The warning, shown once. Writing to a lot of people on your behalf is the
/// only thing in this app that cannot be undone, so it is worth a deliberate
/// yes -- and worth being able to turn off, because a warning that appears
/// every single time is one nobody reads.
struct ConsentStep: View {
    let onCancel: () -> Void
    let onContinue: (Bool) -> Void

    @State private var hasAgreed = false
    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Before Maily writes for you",
                subtitle: "A few things worth knowing."
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    point("sparkles", "Maily writes the drafts",
                          "It reads each email and writes a reply in the style you pick.")
                    point("eye", "You read every one",
                          "Nothing is sent until you send it. Drafts are editable.")
                    point("exclamationmark.triangle", "It can be wrong",
                          "AI can misread a message or invent a detail. Check anything that commits you to something.")
                    point("creditcard", "It costs money",
                          "Each reply uses paid AI. Writing eighty costs more than writing five.")
                    point("arrow.uturn.backward.slash", "Sent mail cannot be recalled",
                          "Once a reply goes, it has gone.")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 12) {
                Toggle(isOn: $hasAgreed) {
                    Text("I understand, and I will review each draft")
                        .font(.footnote)
                }
                .toggleStyle(CheckboxToggleStyle())

                Toggle(isOn: $dontAskAgain) {
                    Text("Don't show this again")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(CheckboxToggleStyle())
                .disabled(!hasAgreed)
                .opacity(hasAgreed ? 1 : 0.5)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            PrimaryButton(title: "Continue", isEnabled: hasAgreed) {
                onContinue(dontAskAgain)
            }
        }
        .navigationTitle("Reply with AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A real checkbox. SwiftUI's default Toggle is a switch, which reads as a
/// setting rather than as an agreement.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Writing in progress. A full screen rather than a spinner in a sheet: this
/// can take minutes, and the count climbing is the only honest reassurance
/// there is.
struct GeneratingStep: View {
    let done: Int
    let total: Int

    @State private var spin = false

    private var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: fraction)

                VStack(spacing: 1) {
                    Text("\(done)")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    Text("of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 148, height: 148)

            VStack(spacing: 8) {
                Text(done == 0 ? "Starting" : (fraction >= 0.85 ? "Almost there" : "Writing your replies"))
                    .font(.title3.weight(.bold))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: done == 0)

                Text("Maily is reading each email and writing a reply. Nothing is sent.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 30)
            .padding(.horizontal, 40)

            Spacer()

            Label("Keep Maily open until this finishes.", systemImage: "iphone")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarBackButtonHidden()
    }
}

/// Sending. Same shape as generating, but the warning is stronger, because
/// leaving here stops a send halfway through a list of real people.
struct SendingStep: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: total > 0 ? max(0.02, Double(done) / Double(total)) : 0.02)
                    .stroke(Color(uiColor: .systemGreen),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: done)

                Image(systemName: "paperplane.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(uiColor: .systemGreen))
            }
            .frame(width: 148, height: 148)

            VStack(spacing: 8) {
                Text("Sending \(done) of \(total)")
                    .font(.title3.weight(.bold).monospacedDigit())
                Text("Stay on this screen. Closing Maily now will stop the rest from going.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 30)
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarBackButtonHidden()
    }
}

/// A number the user types, clamped to what actually exists.
struct CustomCountCard: View {
    let maximum: Int
    let isSelected: Bool
    let current: Int
    let onChange: (Int) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "number")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 26)
                Text("A specific number")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
                if isSelected {
                    Text("\(current)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }

            if isFocused || isSelected {
                TextField("0", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .focused($isFocused)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    }
                    .onChange(of: text) { _, value in
                        // Digits only, and never more than exist. Asking for
                        // fifty out of twelve means twelve.
                        let digits = value.filter(\.isNumber)
                        if digits != value { text = digits }
                        let requested = Int(digits) ?? 0
                        if requested > maximum { text = "\(maximum)" }
                        onChange(min(max(requested, 0), maximum))
                    }
                Text("Up to \(maximum)")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(Color.accentColor)
                      : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)))
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

/// One draft in the review list.
struct DraftCard: View {
    @Binding var draft: BulkReplyFlow.PendingReply
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SenderAvatar(contact: draft.message.sender, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.message.sender.name)
                        .font(.subheadline.weight(.semibold))
                    Text(draft.message.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TextField("Reply", text: $draft.body, axis: .vertical)
                .font(.subheadline)
                .lineLimit(3...10)

            if let failure = draft.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if draft.isSent {
                Label("Sent", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button(action: onSend) {
                    Label("Send this one", systemImage: "paperplane.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StyleChip: View {
    let option: WriterStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: option.systemImage).font(.caption.weight(.semibold))
                Text(option.title).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
            }
        }
        .buttonStyle(.plain)
    }
}

/// Title and subtitle in the onboarding shape, so a flow that asks the user
/// questions looks like the other flow that asks the user questions.
struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }
}

struct PrimaryButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!isEnabled)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
    )
}

extension View {
    /// Tapping anywhere that is not a field puts the keyboard away.
    ///
    /// `simultaneousGesture` rather than `onTapGesture`: the latter swallows
    /// the tap, so buttons underneath stop working.
    func dismissesKeyboardOnTap() -> some View {
        simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }
}
