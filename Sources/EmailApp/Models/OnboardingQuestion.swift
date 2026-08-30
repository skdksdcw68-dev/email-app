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
        /// artwork at a fixed weight and ignore Dynamic Type, tint and dark
        /// mode. Every option carries one.
        let symbol: String
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
    static let all: [OnboardingQuestion] = [
        role, usage, priorities, responseTime, autonomy, tone, approvals, delegate,
    ]

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

    static let usage = OnboardingQuestion(
        id: "usage",
        title: "What do you mainly use email for?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .grid,
        options: [
            .init(id: "work", label: "Work", symbol: "briefcase.fill"),
            .init(id: "business", label: "Business", symbol: "building.2.fill"),
            .init(id: "clients", label: "Clients & customers", symbol: "person.2.fill"),
            .init(id: "team", label: "Team communication", symbol: "person.3.fill"),
            .init(id: "sales", label: "Sales & leads", symbol: "chart.line.uptrend.xyaxis"),
            .init(id: "meetings", label: "Meetings & scheduling", symbol: "calendar"),
            .init(id: "projects", label: "Projects & collaboration", symbol: "folder.fill"),
            .init(id: "invoices", label: "Invoices & payments", symbol: "creditcard.fill"),
            .init(id: "jobs", label: "Job opportunities", symbol: "doc.text.fill"),
            .init(id: "school", label: "School / university", symbol: "graduationcap.fill"),
            .init(id: "personal", label: "Personal conversations", symbol: "message.fill"),
            .init(id: "shopping", label: "Shopping & orders", symbol: "bag.fill"),
            .init(id: "newsletters", label: "News & newsletters", symbol: "newspaper.fill"),
            .init(id: "travel", label: "Travel & bookings", symbol: "airplane"),
            .init(id: "support", label: "Customer support", symbol: "questionmark.circle.fill"),
            .init(id: "other", label: "Other", symbol: "ellipsis.circle.fill"),
        ]
    )

    static let priorities = OnboardingQuestion(
        id: "priorities",
        title: "Which emails matter most?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .grid,
        options: [
            .init(id: "clients", label: "Clients & customers", symbol: "person.2.fill"),
            .init(id: "business", label: "Important business contacts", symbol: "briefcase.fill"),
            .init(id: "team", label: "My team", symbol: "person.3.fill"),
            .init(id: "execs", label: "Managers / executives", symbol: "star.circle.fill"),
            .init(id: "opportunities", label: "Sales opportunities", symbol: "chart.line.uptrend.xyaxis"),
            .init(id: "leads", label: "New leads", symbol: "person.badge.plus"),
            .init(id: "meetings", label: "Meetings & invitations", symbol: "calendar"),
            .init(id: "payments", label: "Payments & invoices", symbol: "creditcard.fill"),
            .init(id: "jobs", label: "Job opportunities", symbol: "doc.text.fill"),
            .init(id: "family", label: "Family & close friends", symbol: "heart.fill"),
            .init(id: "projects", label: "Existing projects", symbol: "folder.fill"),
            .init(id: "support", label: "Support requests", symbol: "questionmark.circle.fill"),
            .init(id: "notifications", label: "Important notifications", symbol: "bell.fill"),
            .init(id: "personal", label: "Personal messages", symbol: "message.fill"),
            .init(id: "deadlines", label: "Deadlines & reminders", symbol: "clock.fill"),
            .init(id: "other", label: "Other", symbol: "ellipsis.circle.fill"),
        ]
    )

    static let responseTime = OnboardingQuestion(
        id: "response_time",
        title: "How quickly do you usually need to respond?",
        subtitle: nil,
        selection: .single,
        layout: .list,
        options: [
            .init(id: "immediately", label: "Immediately", symbol: "bolt.fill"),
            .init(id: "hour", label: "Within an hour", symbol: "clock.fill"),
            .init(id: "few_hours", label: "Within a few hours", symbol: "hourglass"),
            .init(id: "end_of_day", label: "By the end of the day", symbol: "sunset.fill"),
            .init(id: "one_two_days", label: "Within 1-2 days", symbol: "calendar"),
            .init(id: "week", label: "Within the week", symbol: "calendar.badge.clock"),
            .init(id: "whenever", label: "Whenever I get time", symbol: "tortoise.fill"),
            .init(id: "depends", label: "It depends on the sender", symbol: "slider.horizontal.3"),
        ]
    )

    static let autonomy = OnboardingQuestion(
        id: "autonomy",
        title: "How much should your AI handle?",
        subtitle: nil,
        selection: .single,
        layout: .list,
        options: [
            .init(id: "summarize", label: "Just read and summarize", symbol: "text.alignleft"),
            .init(id: "organize", label: "Just organize", symbol: "tray.2.fill"),
            .init(id: "draft", label: "Organize + draft replies", symbol: "square.and.pencil"),
            .init(id: "assist", label: "Assist me", symbol: "hand.raised.fill"),
            .init(id: "routine", label: "Handle routine emails", symbol: "gearshape.2.fill"),
            .init(id: "maximum", label: "Handle as much as possible", symbol: "wand.and.stars"),
        ]
    )

    static let tone = OnboardingQuestion(
        id: "tone",
        title: "How should your AI sound?",
        subtitle: "This is the voice it writes your replies in.",
        selection: .single,
        layout: .list,
        options: [
            .init(id: "match_me", label: "Match how I already write", symbol: "text.quote"),
            .init(id: "professional", label: "Formal & professional", symbol: "briefcase.fill"),
            .init(id: "warm", label: "Warm & friendly", symbol: "heart.fill"),
            .init(id: "direct", label: "Short & direct", symbol: "bolt.fill"),
            .init(id: "thorough", label: "Detailed & thorough", symbol: "doc.text.fill"),
            .init(id: "casual", label: "Casual", symbol: "face.smiling"),
        ]
    )

    static let approvals = OnboardingQuestion(
        id: "approvals",
        title: "What should your AI ask you before doing?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .list,
        options: [
            .init(id: "send", label: "Send an email", symbol: "paperplane.fill"),
            .init(id: "reply", label: "Reply to someone", symbol: "arrowshape.turn.up.left.fill"),
            .init(id: "reply_client", label: "Reply to clients", symbol: "person.2.fill"),
            .init(id: "forward", label: "Forward an email", symbol: "arrowshape.turn.up.right.fill"),
            .init(id: "delete", label: "Delete an email", symbol: "trash.fill"),
            .init(id: "archive", label: "Archive an email", symbol: "archivebox.fill"),
            .init(id: "unsubscribe", label: "Unsubscribe me", symbol: "bell.slash.fill"),
            .init(id: "schedule", label: "Schedule something", symbol: "calendar"),
            .init(id: "settings", label: "Change important settings", symbol: "gearshape.fill"),
            .init(id: "nothing", label: "Nothing, I trust my AI", symbol: "checkmark.shield.fill", isExclusive: true),
        ]
    )

    static let delegate = OnboardingQuestion(
        id: "delegate",
        title: "What would you most like your AI to handle?",
        subtitle: "Select all that apply.",
        selection: .multiple,
        layout: .list,
        options: [
            .init(id: "clutter", label: "Inbox clutter", symbol: "tray.2.fill"),
            .init(id: "forgotten", label: "Emails I forget to reply to", symbol: "clock.arrow.circlepath"),
            .init(id: "urgent", label: "Finding urgent emails", symbol: "exclamationmark.triangle.fill"),
            .init(id: "writing", label: "Writing replies", symbol: "square.and.pencil"),
            .init(id: "promotions", label: "Newsletters & promotions", symbol: "newspaper.fill"),
            .init(id: "notifications", label: "Too many notifications", symbol: "bell.fill"),
            .init(id: "scheduling", label: "Scheduling", symbol: "calendar"),
            .init(id: "finding", label: "Finding information", symbol: "magnifyingglass"),
            .init(id: "repetitive", label: "Repetitive emails", symbol: "arrow.triangle.2.circlepath"),
            .init(id: "everything", label: "Everything I can delegate", symbol: "wand.and.stars"),
        ]
    )
}
