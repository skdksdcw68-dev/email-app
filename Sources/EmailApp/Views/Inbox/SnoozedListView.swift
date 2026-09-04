import SwiftUI

/// Everything put away, and when it comes back.
///
/// A snoozed message is out of the inbox, which means without this screen it
/// is out of the app. The date is on every row for the same reason: "later"
/// is only useful if you can check what later meant.
struct SnoozedListView: View {
    @Environment(MailStore.self) private var mail

    var body: some View {
        // Read so the list redraws when something is woken. Snoozing lives in
        // UserDefaults, which nothing observes on its own.
        _ = mail.preferencesVersion

        let sleeping = SnoozeStore.sleeping()
        let byRemoteID = Dictionary(
            mail.messages.compactMap { message in
                message.remoteID.map { ($0, message) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = sleeping.compactMap { entry in
            byRemoteID[entry.id].map { (message: $0, until: entry.until) }
        }

        return List {
            ForEach(rows, id: \.message.id) { row in
                ZStack {
                    NavigationLink(value: row.message.id) { EmptyView() }.opacity(0)
                    VStack(alignment: .leading, spacing: 6) {
                        MessageRow(message: row.message)
                        Label(back(at: row.until), systemImage: "clock")
                            .font(Style.caption.weight(.medium))
                            .foregroundStyle(Color.snoozed)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        SnoozeStore.wake(row.message.remoteID ?? "")
                        mail.notePreferencesChanged()
                    } label: {
                        Label("Wake", systemImage: "bell")
                    }
                    .tint(Color.snoozed)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Snoozed")
        .navigationBarTitleDisplayMode(.inline)
        // Every other pushed screen hides it; this one was missed.
        .hidesTabBar()
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing snoozed",
                    systemImage: "clock",
                    description: Text("Swipe a message and choose Snooze to put it off until a day that suits.")
                )
            }
        }
        // Snoozing is a Maily idea, not a Gmail one, and the app has to say so
        // rather than let somebody assume their phone and the web agree.
        .safeAreaInset(edge: .bottom) {
            if !rows.isEmpty {
                Text("Snoozing happens on this phone. In Gmail these never left the inbox.")
                    .font(Style.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .screenGutter()
                    .padding(.bottom, Style.tight)
            }
        }
    }

    /// "Tomorrow, 08:00" rather than a bare date -- the day is the part that
    /// matters and the clock is the part that reassures.
    private func back(at date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Back today, \(time)" }
        if calendar.isDateInTomorrow(date) { return "Back tomorrow, \(time)" }

        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear)
            ? "EEEE"
            : "d MMM"
        return "Back \(formatter.string(from: date)), \(time)"
    }
}
