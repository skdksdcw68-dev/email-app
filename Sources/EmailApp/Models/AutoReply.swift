import Foundation

/// What Maily has been authorised to answer on somebody's behalf.
///
/// The point of the whole thing: a founder or a freelancer gets the same five
/// questions every week, and answering them is not work, it is friction. This
/// is where they teach Maily their business once, say what it may answer and
/// what must always come back to them, and stop typing the same reply.
///
/// It is built to fail closed. Every boundary defaults to "ask me", nothing
/// outside the approved knowledge may be invented, and the runtime starts in
/// draft mode -- Maily writes, the person sends -- until the verification
/// layer exists. Autonomous sending is the destination, not the first step,
/// and it is behind its own switch that nothing but a person can throw.
struct AutoReplyConfig: Codable, Equatable {

    /// Whether Maily acts on incoming mail at all. Turning this off keeps
    /// everything below it: a person switching it off for a week is not
    /// asking to answer twenty questions again.
    var isOn = false
    /// Whether the setup has been through to the end. Separate from `isOn`
    /// so a half-finished setup never runs.
    var isSetUp = false

    /// What Maily does with a reply it is confident about.
    var mode: RunMode = .draft

    var persona: Persona?
    var business = BusinessKnowledge()
    /// What it may answer without asking.
    var allowed: Set<Category> = []
    /// What must always come back, whatever else says otherwise.
    var mustAsk: Set<Boundary> = Set(Boundary.allCases.filter(\.isRecommended))
    /// What to do when it is not sure.
    var whenUnsure: Escalation = .draft
    var instructions: [Instruction] = []
    /// Confirmed on the review screen. Nothing runs until this is true, so
    /// mail is never answered from facts nobody has read back.
    var knowledgeConfirmed = false
    var updatedAt = Date.now

    /// How many kinds of mail it is actually authorised to handle, for the
    /// line on the You tab.
    var handledCount: Int { allowed.count }

    var activeInstructions: [Instruction] {
        instructions.filter(\.isOn)
    }

    /// Ready to act: set up, switched on, and with the facts read back.
    var isRunning: Bool { isOn && isSetUp && knowledgeConfirmed }

    // MARK: - Running

    /// What happens once Maily has decided it can answer something.
    ///
    /// Draft is the first stage and the default, and it stays the default
    /// until a person deliberately changes it. Sending is the only thing
    /// Maily does to the world that cannot be taken back.
    enum RunMode: String, Codable, CaseIterable, Identifiable {
        /// Maily writes it; the person sends it. Nothing leaves on its own.
        case draft
        /// Maily sends it. Only for categories it is allowed, only when the
        /// verification layer passes, and never for anything in `mustAsk`.
        case send

        var id: Self { self }

        var title: String {
            switch self {
            case .draft: "Write it for me"
            case .send: "Send it for me"
            }
        }

        var detail: String {
            switch self {
            case .draft: "Maily writes the reply and holds it. Nothing is sent until you tap send."
            case .send: "Maily sends the reply itself, but only for what you allowed and only when it is sure."
            }
        }
    }

    // MARK: - Who they are

    /// What somebody does, which decides what they are asked next. A founder
    /// and a student do not have the same email, and asking them the same
    /// twelve questions is how a setup flow becomes a form nobody finishes.
    enum Persona: String, Codable, CaseIterable, Identifiable {
        case founder, freelancer, agency, sales, support
        case manager, developer, creator, student, personal, other

        var id: Self { self }

        var title: String {
            switch self {
            case .founder: "Founder / Business owner"
            case .freelancer: "Freelancer / Consultant"
            case .agency: "Agency / Studio"
            case .sales: "Sales / Client-facing"
            case .support: "Support / Customer success"
            case .manager: "Manager / Team lead"
            case .developer: "Developer / Technical"
            case .creator: "Creator / Personal brand"
            case .student: "Student"
            case .personal: "Personal email"
            case .other: "Something else"
            }
        }

        var symbol: String {
            switch self {
            case .founder: "building.2.fill"
            case .freelancer: "person.crop.circle.badge.checkmark"
            case .agency: "square.3.layers.3d"
            case .sales: "chart.line.uptrend.xyaxis"
            case .support: "bubble.left.and.bubble.right.fill"
            case .manager: "person.2.fill"
            case .developer: "chevron.left.forwardslash.chevron.right"
            case .creator: "sparkles"
            case .student: "graduationcap.fill"
            case .personal: "person.fill"
            case .other: "circle.grid.2x2.fill"
            }
        }

        /// The heading over their own questions.
        var prompt: String {
            switch self {
            case .founder: "Tell Maily about your business."
            case .freelancer: "Tell Maily about your work."
            case .agency: "Tell Maily how your studio works."
            case .sales: "Tell Maily what you sell."
            case .support: "Tell Maily what you support."
            case .manager: "Tell Maily what you coordinate."
            case .developer: "Tell Maily what you build."
            case .creator: "Tell Maily about your brand."
            case .student, .personal, .other: "Tell Maily about your email."
            }
        }
    }

    // MARK: - What it may answer

    enum Category: String, Codable, CaseIterable, Identifiable {
        case general, product, pricing, availability, scheduling
        case support, status, faq, qualification, acknowledgement

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General questions"
            case .product: "What you do or sell"
            case .pricing: "Pricing questions"
            case .availability: "Whether you're available"
            case .scheduling: "Scheduling a call"
            case .support: "Support requests"
            case .status: "Order or status questions"
            case .faq: "Things you're asked constantly"
            case .qualification: "Qualifying questions"
            case .acknowledgement: "Thank-yous and acknowledgements"
            }
        }

        var symbol: String {
            switch self {
            case .general: "questionmark.bubble.fill"
            case .product: "shippingbox.fill"
            case .pricing: "tag.fill"
            case .availability: "calendar.badge.clock"
            case .scheduling: "calendar"
            case .support: "lifepreserver.fill"
            case .status: "shippingbox.circle.fill"
            case .faq: "text.book.closed.fill"
            case .qualification: "checklist"
            case .acknowledgement: "hand.thumbsup.fill"
            }
        }
    }

    // MARK: - What must come back

    /// Deliberately phrased as things Maily must NOT handle. A permission
    /// list read the other way round is a list of ways to be wrong.
    enum Boundary: String, Codable, CaseIterable, Identifiable {
        case legal, sensitive, customPricing, negotiation, commitments
        case lowConfidence, refunds, complaints, angry, deadlines
        case outsideKnowledge, anythingNotAllowed

        var id: Self { self }

        var title: String {
            switch self {
            case .legal: "Anything legal or contractual"
            case .sensitive: "Personal or sensitive information"
            case .customPricing: "Custom or negotiated pricing"
            case .negotiation: "Negotiation of any kind"
            case .commitments: "Promising anything new"
            case .lowConfidence: "Anything Maily is unsure about"
            case .refunds: "Refunds and cancellations"
            case .complaints: "Complaints"
            case .angry: "Anyone who sounds upset"
            case .deadlines: "Committing to a deadline"
            case .outsideKnowledge: "Anything outside what I taught it"
            case .anythingNotAllowed: "Everything I didn't explicitly allow"
            }
        }

        /// On unless somebody turns it off. These are the ones where being
        /// wrong costs money, a customer, or a lawyer.
        var isRecommended: Bool {
            switch self {
            case .legal, .sensitive, .customPricing, .negotiation,
                 .commitments, .lowConfidence:
                true
            default:
                false
            }
        }
    }

    // MARK: - When it is not sure

    enum Escalation: String, Codable, CaseIterable, Identifiable {
        case draft, approve, askSender, notify

        var id: Self { self }

        var title: String {
            switch self {
            case .draft: "Write it and leave it for me"
            case .approve: "Ask me before anything goes"
            case .askSender: "Ask them for more detail"
            case .notify: "Do nothing, just tell me"
            }
        }

        var detail: String {
            switch self {
            case .draft: "The reply is ready in Auto-Reply. You send it, or you don't."
            case .approve: "Maily asks you first, every time."
            case .askSender: "Maily replies asking the one question it needs answered."
            case .notify: "Maily leaves it alone and flags it."
            }
        }
    }

    // MARK: - Custom instructions

    /// One rule, in the person's own words, about how their agent behaves.
    ///
    /// Kept as a list rather than one block of text so each can be switched
    /// off, edited or reordered on its own. "Never say I hope you're doing
    /// well" is a rule somebody should be able to retire without rewriting
    /// the other six.
    ///
    /// These change *behaviour*, never *facts*. "Keep replies under eighty
    /// words" belongs here; "our price is two thousand" belongs in
    /// `BusinessKnowledge`, because it is something Maily may state as true.
    /// The setup says so, and the prompt is built so an instruction cannot
    /// become a licence to assert something nobody approved.
    struct Instruction: Identifiable, Codable, Hashable {
        var id = UUID()
        var text: String
        var isOn = true

        init(id: UUID = UUID(), text: String, isOn: Bool = true) {
            self.id = id
            self.text = text
            self.isOn = isOn
        }

        /// Nil for anything that is not a rule: empty, or whitespace.
        init?(cleaning raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            self.init(text: String(trimmed.prefix(280)))
        }

        /// The same rule said twice is one rule.
        func matches(_ other: String) -> Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(other.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }

    /// Examples, shown as placeholder text rather than pre-filled rules --
    /// a setup that fills itself in is a setup nobody reads.
    static let instructionExamples = [
        "Keep replies under 100 words.",
        "Never say \"I hope you're doing well.\"",
        "Be friendly but direct.",
        "For support emails, ask for the order number first.",
        "Never promise a delivery date.",
        "Never discuss discounts unless I approve them.",
    ]
}

/// What the person told Maily about their work, and the only facts it is
/// allowed to state on their behalf.
///
/// Everything here was typed by them and read back to them on the review
/// screen. Nothing else is a fact: if an answer needs something that is not
/// in here, that is an escalation, not a guess.
struct BusinessKnowledge: Codable, Equatable {
    var brand = ""
    var whatItDoes = ""
    var customers = ""
    var offering = ""
    var acceptedWork = ""
    var pricing = ""
    var availability = ""
    var hours = ""
    var regions = ""
    var policies = ""
    var faq = ""
    var links = ""
    var escalationContact = ""
    var notes = ""

    /// Which of these were actually filled in, for the review screen and for
    /// the prompt -- an empty field is not a fact and is never sent.
    var filled: [(label: String, value: String)] {
        let all: [(String, String)] = [
            ("Brand", brand),
            ("What it does", whatItDoes),
            ("Customers", customers),
            ("What you offer", offering),
            ("Work you accept", acceptedWork),
            ("Pricing", pricing),
            ("Availability", availability),
            ("Hours", hours),
            ("Regions", regions),
            ("Policies", policies),
            ("Common questions", faq),
            ("Links", links),
            ("Escalate to", escalationContact),
            ("Anything else", notes),
        ]
        return all.compactMap { label, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (label, trimmed)
        }
    }

    var isEmpty: Bool { filled.isEmpty }
}
