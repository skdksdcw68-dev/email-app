import SwiftUI
import UIKit

// The individual screens and controls of the bulk reply flow, kept out of the
// flow file so that one stays readable as a description of the sequence.

/// The warning, shown once. Writing to a lot of people on your behalf is the
/// only thing in this app that cannot be undone, so it is worth a deliberate
/// yes -- and worth being able to turn off, because a warning that appears
/// every single time is one nobody reads.
struct ConsentStep: View {
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

// MARK: - Flow chrome

/// The X that closes the flow: a small circled mark, the way modern sheets
/// dismiss, instead of a "Cancel" word.
struct FlowCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                .contentShape(Circle())
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel("Close")
    }
}

/// Back, for any step that has somewhere to go back to. Styled like the
/// system's own back control so it reads as navigation, not cancellation.
struct FlowBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                Text("Back")
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel("Back")
    }
}

// MARK: - Working screens

/// Writing in progress.
///
/// A full screen rather than a spinner in a sheet: this can take minutes, and
/// the count climbing is the only honest reassurance there is. Three things
/// keep it alive: a comet that never stops circling, digits that roll rather
/// than swap, and the name of whoever is being written to sliding through.
struct GeneratingStep: View {
    let done: Int
    let total: Int
    var recipient: String? = nil

    @State private var sweep = false

    private var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 10)

                // Always turning, so the screen has a pulse even while one
                // reply is being written.
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        AngularGradient(
                            colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.45)],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(100)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .animation(.linear(duration: 1.3).repeatForever(autoreverses: false), value: sweep)

                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.55, dampingFraction: 0.75), value: fraction)

                VStack(spacing: 2) {
                    Text("\(done)")
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: Double(done)))
                        .animation(.snappy(duration: 0.3), value: done)
                    Text("of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)

            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(done == 0 ? "Starting" : (fraction >= 0.85 ? "Almost there" : "Writing your replies"))
                }
                .font(.title3.weight(.bold))

                // Who the current draft is for. `.id` makes each name its own
                // view, so one slides out as the next slides in.
                ZStack {
                    if let recipient {
                        Text("Writing to \(recipient)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .id(recipient)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    } else {
                        Text("Maily is reading each email. Nothing is sent.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 20)
                .clipped()
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: recipient)
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
        .sensoryFeedback(.impact(weight: .light), trigger: done)
        .onAppear { sweep = true }
    }
}

/// Sending. Same shape as generating, but green, with the plane drifting on a
/// slow bob so the screen breathes -- and the warning is stronger, because
/// leaving here stops a send halfway through a list of real people.
struct SendingStep: View {
    let done: Int
    let total: Int

    @State private var bob = false

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
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: done)

                Image(systemName: "paperplane.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(uiColor: .systemGreen))
                    .rotationEffect(.degrees(bob ? -6 : 6))
                    .offset(x: bob ? 4 : -4, y: bob ? -5 : 3)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: bob)
            }
            .frame(width: 156, height: 156)

            VStack(spacing: 8) {
                Text("Sending \(done) of \(total)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(done)))
                    .animation(.snappy(duration: 0.3), value: done)
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
        .sensoryFeedback(.impact(weight: .light), trigger: done)
        .onAppear { bob = true }
    }
}

/// The landing after a send: the checkmark springs in with a success haptic
/// instead of already sitting there, so arriving reads as an event.
struct DoneStep: View {
    let sent: Int
    let hadFailures: Bool
    let onDone: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(uiColor: .systemGreen).opacity(0.12))
                    .frame(width: 140, height: 140)
                    .scaleEffect(appeared ? 1 : 0.4)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(Color(uiColor: .systemGreen))
                    .scaleEffect(appeared ? 1 : 0.3)
                    .symbolEffect(.bounce, value: appeared)
            }
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 6) {
                Text(sent == 1 ? "1 reply sent" : "\(sent) replies sent")
                    .font(.title2.weight(.bold))
                if hadFailures {
                    Text("Some could not be sent. Go back to see which.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            Spacer()

            PrimaryButton(title: "Back to inbox", isEnabled: true, action: onDone)
        }
        .padding(.horizontal, 4)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: appeared)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.15)) {
                appeared = true
            }
        }
    }
}

// MARK: - Review pieces

/// One draft in the review list. Its send button carries the whole story:
/// idle, spinning while it goes, then a green "Sent" it morphs into.
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
                .disabled(draft.isSent || draft.isSending)

            if let failure = draft.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Group {
                if draft.isSent {
                    Label("Sent", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .systemGreen))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Capsule().fill(Color(uiColor: .systemGreen).opacity(0.12)))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Nothing was written for this one, usually because the
                    // network dropped mid-run. Offering "Send" here was the
                    // bug: it promised to send an empty reply.
                    Label("Could not be written. Try again later.", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: onSend) {
                        HStack(spacing: 8) {
                            if draft.isSending {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text(draft.isSending ? "Sending…" : "Send this one")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Capsule().fill(Color.accentColor.opacity(draft.isSending ? 0.75 : 1)))
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .disabled(draft.isSending)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: draft.isSent)
            .animation(.easeInOut(duration: 0.18), value: draft.isSending)
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
        .buttonStyle(BouncyButtonStyle())
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
