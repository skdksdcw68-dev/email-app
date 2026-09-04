import SwiftUI

/// Choosing when a message comes back.
///
/// A sheet rather than an action sheet, and for one reason: the choices need
/// to say when they actually mean. "This weekend" from an action sheet is a
/// guess -- here it says Sat, 08:00 beside it, so the choice is made on the
/// date rather than on the word.
///
/// Sized to its content, so it covers as little of the mail as it needs to.
struct SnoozeSheet: View {
    let subject: String
    let onPick: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ForEach(Array(SnoozeStore.When.allCases.enumerated()), id: \.element) { index, when in
                    Button {
                        onPick(when.date())
                        dismiss()
                    } label: {
                        row(when)
                    }
                    .buttonStyle(.plain)

                    if index < SnoozeStore.When.allCases.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }

                // Said here rather than buried in Settings. Somebody who
                // snoozes on their phone and then opens Gmail on a laptop
                // should not have to work this out for themselves.
                Text("This happens on your phone only. In Gmail the message never moves.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                Spacer(minLength: 0)
            }
            .navigationTitle("Snooze until")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    FlowCloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func row(_ when: SnoozeStore.When) -> some View {
        HStack(spacing: 14) {
            Image(systemName: when.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(Color.indigo.opacity(0.12))
                }

            Text(when.title)
                .font(.body)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text(stamp(when.date()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// "Tomorrow, 08:00", "Sat, 08:00", "14 Sep, 08:00" -- whichever is the
    /// shortest thing that still says which day.
    private func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)

        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return "Tomorrow, \(time)" }

        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear)
            ? "EEE"
            : "d MMM"
        return "\(formatter.string(from: date)), \(time)"
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            SnoozeSheet(subject: "Invoice for August") { _ in }
        }
}
