import Foundation

/// One onboarding question. Questions are data, not hand-written screens, so
/// there is a single view to maintain and the set can be reordered or edited
/// without touching any SwiftUI.
struct OnboardingQuestion: Identifiable, Hashable {
    enum Selection { case single, multiple }
    enum Layout { case grid, list }

    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        /// An SF Symbol name, not an emoji. Emoji render as someone else's
        /// artwork at a fixed weight and do not respond to Dynamic Type,
        /// tint, or dark mode. SF Symbols do all three.
        var symbol: String? = nil
        /// Picking this clears every other choice, and picking anything else
        /// clears this. "Nothing, I trust my AI" cannot coexist with a list of
        /// things you want to approve.
        var isExclusive: Bool = false
    }

    let id: String
    let title: String
    let subtitle: String?
    let selection: Selection
    let layout: Layout
    let options: [Option]
}

extension OnboardingQuestion {
    /// Eight questions -- the count is deliberately divisible by 2.
    ///
    /// The draft had seven. `tone` was added rather than dropping one, and it
    /// earns its place: `autonomy` already offers to draft replies, and none of
    /// the other questions tell the AI how those replies should sound.
    static let all: [OnboardingQuestion] = [
        role, usage, priorities, responseTime, autonomy, tone, approvals, delegate,
    ]

    static let usage = OnboardingQuestion(
        id: "usage",
        title: "What do you mainly use email for?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .grid,
        options: [
            .init(id: "work", label: "Work"),
            .init(id: "business", label: "Business"),
            .init(id: "clients", label: "Clients & customers"),
            .init(id: "team", label: "Team communication"),
            .init(id: "sales", label: "Sales & leads"),
            .init(id: "meetings", label: "Meetings & scheduling"),
            .init(id: "projects", label: "Projects & collaboration"),
            .init(id: "invoices", label: "Invoices & payments"),
            .init(id: "jobs", label: "Job opportunities"),
            .init(id: "school", label: "School / university"),
            .init(id: "personal", label: "Personal conversations"),
            .init(id: "shopping", label: "Shopping & orders"),
            .init(id: "newsletters", label: "News & newsletters"),
            .init(id: "travel", label: "Travel & bookings"),
            .init(id: "support", label: "Customer support"),
            .init(id: "other", label: "Other"),
        ]
    )

    static let tone = OnboardingQuestion(
        id: "tone",
        title: "How should your AI sound?",
        subtitle: "This is the voice it writes your replies in.",
        selection: .single,
        layout: .list,
        options: [
            .init(id: "match_me", label: "Match how I already write"),
            .init(id: "professional", label: "Formal & professional"),
            .init(id: "warm", label: "Warm & friendly"),
            .init(id: "direct", label: "Short & direct"),
            .init(id: "thorough", label: "Detailed & thorough"),
            .init(id: "casual", label: "Casual"),
        ]
    )

    static let role = OnboardingQuestion(
        id: "role",
        title: "What describes you best?",
        subtitle: "We use this to make your AI work the way you do.",
        selection: .single,
        layout: .grid,
        options: [
            .init(id: "business_owner", label: "Business owner", symbol: "building.2.fill"),
            .init(id: "founder", label: "Entrepreneur / Founder", symbol: "lightbulb.fill"),
            .init(id: "professional", label: "Professional", symbol: "briefcase.fill"),
            .init(id: "manager", label: "Manager / Team lead", symbol: "person.3.fill"),
            .init(id: "sales", label: "Sales / Client-facing", symbol: "megaphone.fill"),
            .init(id: "freelancer", label: "Freelancer / Consultant", symbol: "laptopcomputer"),
            .init(id: "student", label: "Student", symbol: "graduationcap.fill"),
            .init(id: "personal", label: "Personal email user", symbol: "person.fill"),
        ]
    )

    static let priorities = OnboardingQuestion(
        id: "priorities",
        title: "Which emails matter most?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .grid,
        options: [
            .init(id: "clients", label: "Clients & customers"),
            .init(id: "business", label: "Important business contacts"),
            .init(id: "team", label: "My team"),
            .init(id: "execs", label: "Managers / executives"),
            .init(id: "opportunities", label: "Sales opportunities"),
            .init(id: "leads", label: "New leads"),
            .init(id: "meetings", label: "Meetings & invitations"),
            .init(id: "payments", label: "Payments & invoices"),
            .init(id: "jobs", label: "Job opportunities"),
            .init(id: "family", label: "Family & close friends"),
            .init(id: "projects", label: "Existing projects"),
            .init(id: "support", label: "Support requests"),
            .init(id: "notifications", label: "Important notifications"),
            .init(id: "personal", label: "Personal messages"),
            .init(id: "deadlines", label: "Deadlines & reminders"),
            .init(id: "other", label: "Other"),
        ]
    )

    static let responseTime = OnboardingQuestion(
        id: "response_time",
        title: "How quickly do you usually need to respond?",
        subtitle: nil,
        selection: .single,
        layout: .list,
        options: [
            .init(id: "immediately", label: "Immediately"),
            .init(id: "hour", label: "Within an hour"),
            .init(id: "few_hours", label: "Within a few hours"),
            .init(id: "end_of_day", label: "By the end of the day"),
            .init(id: "one_two_days", label: "Within 1-2 days"),
            .init(id: "week", label: "Within the week"),
            .init(id: "whenever", label: "Whenever I get time"),
            .init(id: "depends", label: "It depends on the sender"),
        ]
    )

    static let autonomy = OnboardingQuestion(
        id: "autonomy",
        title: "How much should your AI handle?",
        subtitle: nil,
        selection: .single,
        layout: .list,
        options: [
            .init(id: "summarize", label: "Just read and summarize"),
            .init(id: "organize", label: "Just organize"),
            .init(id: "draft", label: "Organize + draft replies"),
            .init(id: "assist", label: "Assist me"),
            .init(id: "routine", label: "Handle routine emails"),
            .init(id: "maximum", label: "Handle as much as possible"),
        ]
    )

    static let approvals = OnboardingQuestion(
        id: "approvals",
        title: "What should your AI ask you before doing?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .list,
        options: [
            .init(id: "send", label: "Send an email"),
            .init(id: "reply", label: "Reply to someone"),
            .init(id: "reply_client", label: "Reply to clients"),
            .init(id: "forward", label: "Forward an email"),
            .init(id: "delete", label: "Delete an email"),
            .init(id: "archive", label: "Archive an email"),
            .init(id: "unsubscribe", label: "Unsubscribe me"),
            .init(id: "schedule", label: "Schedule something"),
            .init(id: "settings", label: "Change important settings"),
            .init(id: "nothing", label: "Nothing, I trust my AI", isExclusive: true),
        ]
    )

    static let delegate = OnboardingQuestion(
        id: "delegate",
        title: "What would you most like your AI to handle?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .list,
        options: [
            .init(id: "clutter", label: "Inbox clutter"),
            .init(id: "forgotten", label: "Emails I forget to reply to"),
            .init(id: "urgent", label: "Finding urgent emails"),
            .init(id: "writing", label: "Writing replies"),
            .init(id: "promotions", label: "Newsletters & promotions"),
            .init(id: "notifications", label: "Too many notifications"),
            .init(id: "scheduling", label: "Scheduling"),
            .init(id: "finding", label: "Finding information"),
            .init(id: "repetitive", label: "Repetitive emails"),
            .init(id: "everything", label: "Everything I can delegate"),
        ]
    )
}
