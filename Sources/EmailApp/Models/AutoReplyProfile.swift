import Foundation

/// The choices the setup collects, and the options offered for each.
///
/// Everything here is a selection rather than a question with a text box. A
/// person setting this up is not writing a brief; they are telling Maily what
/// kind of work they do so it can ask the right next thing. Typing is asked
/// for only where a choice genuinely cannot say it -- a price, a policy, a
/// rule in their own words.
///
/// The options are persona-aware, so a freelancer and a support lead are not
/// shown the same twelve cards. That is the difference between a setup that
/// feels guided and a form.
enum AutoReplyOptions {

    /// One selectable card. Same shape as an onboarding option, deliberately,
    /// because it is drawn by the same chrome.
    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        let symbol: String

        init(_ id: String, _ label: String, _ symbol: String) {
            self.id = id
            self.label = label
            self.symbol = symbol
        }
    }

    // MARK: - What they mostly email about

    static func work(for persona: AutoReplyConfig.Persona) -> [Option] {
        switch persona {
        case .founder:
            [Option("customers", "Customers", "person.2.fill"),
             Option("sales", "Sales", "chart.line.uptrend.xyaxis"),
             Option("partnerships", "Partnerships", "handshake.fill"),
             Option("hiring", "Hiring", "person.badge.plus"),
             Option("operations", "Operations", "gearshape.fill"),
             Option("projects", "Projects", "folder.fill"),
             Option("support", "Support", "lifepreserver.fill"),
             Option("payments", "Payments", "creditcard.fill"),
             Option("scheduling", "Scheduling", "calendar")]
        case .freelancer:
            [Option("dev", "Development", "chevron.left.forwardslash.chevron.right"),
             Option("design", "Design", "paintbrush.fill"),
             Option("writing", "Writing", "text.alignleft"),
             Option("marketing", "Marketing", "megaphone.fill"),
             Option("consulting", "Consulting", "briefcase.fill"),
             Option("video", "Video / creative", "video.fill"),
             Option("other", "Something else", "circle.grid.2x2.fill")]
        case .agency:
            [Option("design", "Design", "paintbrush.fill"),
             Option("dev", "Development", "chevron.left.forwardslash.chevron.right"),
             Option("marketing", "Marketing", "megaphone.fill"),
             Option("branding", "Branding", "sparkles"),
             Option("content", "Content", "text.alignleft"),
             Option("strategy", "Strategy", "map.fill")]
        case .sales:
            [Option("products", "Products", "shippingbox.fill"),
             Option("services", "Services", "briefcase.fill"),
             Option("subscriptions", "Subscriptions", "arrow.triangle.2.circlepath"),
             Option("demos", "Demos", "play.rectangle.fill"),
             Option("renewals", "Renewals", "calendar.badge.clock")]
        case .support:
            [Option("access", "Account access", "key.fill"),
             Option("billing", "Billing", "creditcard.fill"),
             Option("technical", "Technical issues", "wrench.and.screwdriver.fill"),
             Option("orders", "Orders", "shippingbox.fill"),
             Option("product", "Product questions", "questionmark.circle.fill"),
             Option("refunds", "Refunds", "arrow.uturn.backward"),
             Option("faq", "FAQ", "text.book.closed.fill")]
        case .manager:
            [Option("team", "Team coordination", "person.2.fill"),
             Option("scheduling", "Scheduling", "calendar"),
             Option("projects", "Projects", "folder.fill"),
             Option("approvals", "Approvals", "checkmark.seal.fill"),
             Option("external", "External partners", "building.2.fill"),
             Option("operations", "Operations", "gearshape.fill")]
        case .developer:
            [Option("apps", "Apps", "app.fill"),
             Option("saas", "SaaS", "cloud.fill"),
             Option("integrations", "Integrations", "arrow.triangle.branch"),
             Option("consulting", "Consulting", "briefcase.fill"),
             Option("opensource", "Open source", "chevron.left.forwardslash.chevron.right"),
             Option("infra", "Infrastructure", "server.rack")]
        case .creator:
            [Option("sponsorship", "Sponsorships", "dollarsign.circle.fill"),
             Option("collabs", "Collaborations", "person.2.fill"),
             Option("press", "Press", "newspaper.fill"),
             Option("audience", "Audience questions", "bubble.left.fill"),
             Option("products", "My own products", "shippingbox.fill")]
        case .student:
            [Option("school", "School", "graduationcap.fill"),
             Option("applications", "Applications", "doc.text.fill"),
             Option("projects", "Projects", "folder.fill"),
             Option("internships", "Internships", "briefcase.fill"),
             Option("personal", "Personal", "person.fill")]
        case .personal, .other:
            [Option("personal", "Personal", "person.fill"),
             Option("admin", "Admin and accounts", "doc.text.fill"),
             Option("shopping", "Orders and shopping", "shippingbox.fill"),
             Option("appointments", "Appointments", "calendar"),
             Option("work", "Work", "briefcase.fill")]
        }
    }

    static func workTitle(for persona: AutoReplyConfig.Persona) -> String {
        switch persona {
        case .founder, .manager: "What do you mostly email about?"
        case .freelancer, .agency: "What kind of work do you do?"
        case .sales: "What do you sell?"
        case .support: "What do you support people with?"
        case .developer: "What do you build?"
        case .creator: "What lands in your inbox?"
        case .student, .personal, .other: "What is your email mostly about?"
        }
    }

    // MARK: - Who writes to them

    static func audience(for persona: AutoReplyConfig.Persona) -> [Option] {
        switch persona {
        case .founder, .sales:
            [Option("customers", "Customers", "person.2.fill"),
             Option("leads", "New leads", "sparkles"),
             Option("partners", "Partners", "handshake.fill"),
             Option("investors", "Investors", "chart.line.uptrend.xyaxis"),
             Option("suppliers", "Suppliers", "shippingbox.fill"),
             Option("team", "My team", "person.3.fill")]
        case .freelancer, .developer:
            [Option("startups", "Startups", "sparkles"),
             Option("founders", "Founders", "person.fill"),
             Option("small", "Small businesses", "building.fill"),
             Option("agencies", "Agencies", "square.3.layers.3d"),
             Option("enterprise", "Enterprise", "building.2.fill"),
             Option("individuals", "Individuals", "person.crop.circle")]
        case .agency:
            [Option("brands", "Brands", "sparkles"),
             Option("startups", "Startups", "bolt.fill"),
             Option("enterprise", "Enterprise", "building.2.fill"),
             Option("nonprofits", "Non-profits", "heart.fill"),
             Option("agencies", "Other agencies", "square.3.layers.3d")]
        case .support:
            [Option("customers", "Customers", "person.2.fill"),
             Option("trials", "Trial users", "clock.fill"),
             Option("enterprise", "Enterprise accounts", "building.2.fill"),
             Option("partners", "Partners", "handshake.fill")]
        case .manager:
            [Option("team", "My team", "person.3.fill"),
             Option("leadership", "Leadership", "star.fill"),
             Option("partners", "External partners", "building.2.fill"),
             Option("vendors", "Vendors", "shippingbox.fill")]
        case .creator:
            [Option("brands", "Brands", "sparkles"),
             Option("audience", "My audience", "person.3.fill"),
             Option("press", "Press", "newspaper.fill"),
             Option("agencies", "Agencies", "square.3.layers.3d")]
        case .student, .personal, .other:
            [Option("schools", "Schools", "graduationcap.fill"),
             Option("employers", "Employers", "briefcase.fill"),
             Option("services", "Services and accounts", "gearshape.fill"),
             Option("people", "People I know", "person.2.fill")]
        }
    }

    // MARK: - What they get asked

    static func inbound(for persona: AutoReplyConfig.Persona) -> [Option] {
        let base = [
            Option("general", "General questions", "questionmark.bubble.fill"),
            Option("info", "What you do", "info.circle.fill"),
            Option("pricing", "Pricing", "tag.fill"),
            Option("availability", "Availability", "calendar.badge.clock"),
            Option("scheduling", "Scheduling a call", "calendar"),
        ]
        let extra: [Option] = switch persona {
        case .founder, .sales:
            [Option("newwork", "New business", "sparkles"),
             Option("support", "Support", "lifepreserver.fill"),
             Option("orders", "Orders and status", "shippingbox.fill"),
             Option("partnerships", "Partnerships", "handshake.fill")]
        case .freelancer, .agency, .developer:
            [Option("newwork", "New projects", "sparkles"),
             Option("technical", "Technical questions", "chevron.left.forwardslash.chevron.right"),
             Option("existing", "Existing work", "folder.fill"),
             Option("revisions", "Revisions", "arrow.uturn.backward")]
        case .support:
            [Option("access", "Account access", "key.fill"),
             Option("bugs", "Something is broken", "exclamationmark.triangle.fill"),
             Option("orders", "Orders and status", "shippingbox.fill"),
             Option("refunds", "Refunds", "arrow.uturn.backward")]
        case .creator:
            [Option("collab", "Collaborations", "person.2.fill"),
             Option("sponsorship", "Sponsorships", "dollarsign.circle.fill"),
             Option("press", "Press", "newspaper.fill")]
        case .manager:
            [Option("approvals", "Approvals", "checkmark.seal.fill"),
             Option("updates", "Status updates", "arrow.triangle.2.circlepath")]
        case .student, .personal, .other:
            [Option("admin", "Admin", "doc.text.fill"),
             Option("appointments", "Appointments", "calendar")]
        }
        return base + extra + [Option("thanks", "Thank-yous", "hand.thumbsup.fill")]
    }

    // MARK: - Policies worth writing down

    static func policies(for persona: AutoReplyConfig.Persona) -> [Option] {
        switch persona {
        case .support, .sales, .founder:
            [Option("refunds", "Refunds", "arrow.uturn.backward"),
             Option("cancellations", "Cancellations", "xmark.circle.fill"),
             Option("hours", "Support hours", "clock.fill"),
             Option("turnaround", "Turnaround times", "timer"),
             Option("orders", "Orders", "shippingbox.fill"),
             Option("escalation", "Who to escalate to", "arrow.up.forward.circle.fill")]
        case .freelancer, .agency, .developer:
            [Option("turnaround", "Turnaround times", "timer"),
             Option("revisions", "Revisions", "arrow.uturn.backward"),
             Option("cancellations", "Cancellations", "xmark.circle.fill"),
             Option("hours", "Working hours", "clock.fill"),
             Option("escalation", "Who to escalate to", "arrow.up.forward.circle.fill")]
        default:
            [Option("hours", "When you reply", "clock.fill"),
             Option("escalation", "Who to escalate to", "arrow.up.forward.circle.fill")]
        }
    }

    static func policyLabel(_ id: String) -> String {
        switch id {
        case "refunds": "Refunds"
        case "cancellations": "Cancellations"
        case "hours": "Hours"
        case "turnaround": "Turnaround times"
        case "orders": "Orders"
        case "revisions": "Revisions"
        case "escalation": "Escalate to"
        default: id.capitalized
        }
    }

    static func policyHint(_ id: String) -> String {
        switch id {
        case "refunds": "e.g. Full refund within 14 days, no questions."
        case "cancellations": "e.g. Cancel any time before work starts."
        case "hours": "e.g. Mon–Fri, 9–6 UK time."
        case "turnaround": "e.g. First draft within 5 working days."
        case "orders": "e.g. Orders ship in 2–3 days, tracked."
        case "revisions": "e.g. Two rounds included."
        case "escalation": "e.g. abel@acme.com, or my number."
        default: "The rule, in one line."
        }
    }
}

// MARK: - What Maily worked out

/// The model's own account of what it just learned, shown back before
/// anything is switched on.
///
/// Written by the model from the answers, not assembled from templates on
/// the device. The point of the screen is that a person reads it and either
/// recognises themselves or spots what Maily got wrong -- and a paragraph the
/// app wrote from its own fields could never be wrong, which is exactly what
/// makes it worthless as a check.
struct AutoReplyUnderstanding: Codable, Equatable {
    var role: String
    var work: String
    var audience: String
    var commonRequests: [String]
    var canHandle: [String]
    var alwaysAsks: [String]
    var whenUnsure: String
    var style: String
    var rules: [String]

    /// The sections, in reading order, with the step each one goes back to.
    var sections: [(title: String, body: String, step: String)] {
        var out: [(String, String, String)] = [
            ("Who you are", role, "persona"),
            ("What you do", work, "work"),
            ("Who writes to you", audience, "audience"),
        ]
        if !commonRequests.isEmpty {
            out.append(("What they usually ask", commonRequests.joined(separator: "\n"), "inbound"))
        }
        if !canHandle.isEmpty {
            out.append(("What Maily can handle", canHandle.joined(separator: "\n"), "allowed"))
        }
        if !alwaysAsks.isEmpty {
            out.append(("What always comes to you", alwaysAsks.joined(separator: "\n"), "boundaries"))
        }
        out.append(("When Maily is unsure", whenUnsure, "unsure"))
        out.append(("How you sound", style, "style"))
        if !rules.isEmpty {
            out.append(("Your rules", rules.joined(separator: "\n"), "instructions"))
        }
        return out
    }
}

/// A real reply, written by the model from the setup, with its own account of
/// why it is safe.
///
/// `blockedFacts` is the important half: the things it deliberately did not
/// answer because they needed approval or because nobody gave it the fact.
/// A preview that only shows what it *can* do is an advert; showing what it
/// refused is the thing that earns trust.
struct AutoReplyExample: Codable, Equatable {
    var incoming: String
    var reply: String
    var evidenceUsed: [String]
    var rulesFollowed: [String]
    var blockedFacts: [String]
    var safety: String
}
