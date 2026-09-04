import Foundation
import Observation

/// Owns the Auto-Reply setup: what Maily may answer, what it must bring back,
/// and the rules the person wrote for their own agent.
///
/// One JSON file in Application Support, like the other stores. Deliberately
/// **not** cleared on `.mailboxDisconnected`: this is what somebody taught
/// Maily about their own business, not content read out of their mail, and
/// making them teach it again because they reconnected a mailbox would be the
/// worst possible moment to lose it. Signing out clears it.
@Observable
@MainActor
final class AutoReplyStore {

    private(set) var config = AutoReplyConfig()

    let fileURL: URL

    /// Read in `deinit`, which is not on the main actor. Written once, in
    /// `init`, so there is nothing to race.
    nonisolated(unsafe) private var switchObserver: NSObjectProtocol?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        load()
        adoptActivationForActiveMailbox()

        // The setup is shared across mailboxes; being armed is not. When the
        // mailbox changes, the three fields that decide whether an agent is
        // answering have to change with it -- otherwise switching to a
        // freshly added work account would show, and act on, the personal
        // account's arming.
        switchObserver = NotificationCenter.default.addObserver(
            forName: .activeMailboxChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.adoptActivationForActiveMailbox() }
        }
    }

    deinit {
        if let switchObserver { NotificationCenter.default.removeObserver(switchObserver) }
    }

    private static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Maily", directoryHint: .isDirectory)
            .appending(path: "autoreply.json")
    }

    // MARK: - Setting up

    /// Saves a setup that has been through to the end and switches it on.
    ///
    /// The run mode is deliberately not taken from what is passed in. It
    /// belongs to the person, is changed only through `setMode`, and a first
    /// setup always starts as a draft: sending on somebody's behalf is a
    /// decision they make afterwards, from the Auto-Reply screen, once they
    /// have watched it write a few. Reading it off the incoming config would
    /// mean an edit -- or a setup flow with a stale copy -- could quietly
    /// turn sending on or off behind them.
    func complete(_ config: AutoReplyConfig) {
        var activation = AutoReplyActivation.current
        activation.isOn = true
        activation.mode = self.config.isSetUp ? activation.mode : .draft
        // From now on, not from three months ago. An edit keeps the
        // original line so a tweak does not make it forget what it has
        // already been watching.
        activation.watchingSince = activation.watchingSince ?? .now
        // Armed on the mailbox this was set up from, and only that one.
        AutoReplyActivation.current = activation

        var value = config
        value.instructions = Self.tidied(value.instructions)
        value.isSetUp = true
        value.knowledgeConfirmed = true
        value.isOn = activation.isOn
        value.mode = activation.mode
        value.watchingSince = activation.watchingSince
        value.updatedAt = .now
        self.config = value
        persist()
    }

    /// Keeps everything and stops acting on it. The setup survives, because
    /// switching off for a week and being asked twenty questions again is
    /// how a feature gets switched off for good.
    /// Armed on **this mailbox**, not on the account.
    ///
    /// The setup is shared; being switched on is not. Connecting a work
    /// address to an app where this was already on would otherwise arm an
    /// agent to answer mail from an address nobody consented to, on the first
    /// sync, in a voice tuned for different people. See `AutoReplyActivation`.
    func setOn(_ isOn: Bool) {
        guard config.isSetUp else { return }
        var activation = AutoReplyActivation.current
        activation.isOn = isOn
        // Switching back on after a break starts from now. The week it was
        // off is not a backlog to work through.
        if isOn { activation.watchingSince = .now }
        AutoReplyActivation.current = activation

        config.isOn = isOn
        if isOn { config.watchingSince = activation.watchingSince }
        config.updatedAt = .now
        persist()
    }

    /// The one that matters. Only a person can call this, only from the
    /// Auto-Reply screen, and the UI will not offer `.send` until the
    /// verification layer is in place.
    ///
    /// Per-mailbox too: a mailbox trusted to send is not every mailbox.
    func setMode(_ mode: AutoReplyConfig.RunMode) {
        guard config.isSetUp else { return }
        var activation = AutoReplyActivation.current
        activation.mode = mode
        AutoReplyActivation.current = activation

        config.mode = mode
        config.updatedAt = .now
        persist()
    }

    /// Pulls this mailbox's arming into the config the rest of the app reads.
    ///
    /// Called when the active mailbox changes. The shared file still carries
    /// `isOn`, `mode` and `watchingSince` so every existing reader keeps
    /// working; this is what makes those three tell the truth about the
    /// mailbox actually in front of the person.
    func adoptActivationForActiveMailbox() {
        let activation = AutoReplyActivation.current
        config.isOn = activation.isOn
        config.mode = activation.mode
        config.watchingSince = activation.watchingSince
    }

    /// Wipes the setup entirely. Asked for explicitly, and confirmed.
    func forgetSetup() {
        config = AutoReplyConfig()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Custom instructions
    //
    // Editable on their own, without walking back through the setup. That is
    // the point of them: they are the thing a person tunes after watching a
    // few replies come out slightly wrong.

    /// Adds a rule, unless it is empty or one they already wrote. Returns
    /// false when nothing was added, so the screen can say so rather than
    /// silently doing nothing.
    @discardableResult
    func addInstruction(_ text: String) -> Bool {
        guard let instruction = AutoReplyConfig.Instruction(cleaning: text) else { return false }
        guard !config.instructions.contains(where: { $0.matches(instruction.text) }) else { return false }
        guard config.instructions.count < Self.instructionLimit else { return false }

        config.instructions.append(instruction)
        touch()
        return true
    }

    @discardableResult
    func updateInstruction(_ id: AutoReplyConfig.Instruction.ID, text: String) -> Bool {
        guard let index = config.instructions.firstIndex(where: { $0.id == id }) else { return false }
        guard let cleaned = AutoReplyConfig.Instruction(cleaning: text) else { return false }
        guard !config.instructions.contains(where: { $0.id != id && $0.matches(cleaned.text) }) else { return false }

        config.instructions[index].text = cleaned.text
        touch()
        return true
    }

    func setInstruction(_ id: AutoReplyConfig.Instruction.ID, isOn: Bool) {
        guard let index = config.instructions.firstIndex(where: { $0.id == id }) else { return }
        config.instructions[index].isOn = isOn
        touch()
    }

    func removeInstructions(at offsets: IndexSet) {
        config.instructions.remove(atOffsets: offsets)
        touch()
    }

    func moveInstructions(from source: IndexSet, to destination: Int) {
        config.instructions.move(fromOffsets: source, toOffset: destination)
        touch()
    }

    /// More than this and nobody can hold their own rules in their head, and
    /// the prompt starts arguing with itself.
    static let instructionLimit = 25

    /// Empty ones dropped, whitespace trimmed, duplicates collapsed, and
    /// capped. Run on the way in from the setup flow, where a person may
    /// have typed several at once.
    static func tidied(_ instructions: [AutoReplyConfig.Instruction]) -> [AutoReplyConfig.Instruction] {
        var kept: [AutoReplyConfig.Instruction] = []
        for instruction in instructions {
            guard let cleaned = AutoReplyConfig.Instruction(cleaning: instruction.text) else { continue }
            guard !kept.contains(where: { $0.matches(cleaned.text) }) else { continue }
            kept.append(
                AutoReplyConfig.Instruction(id: instruction.id, text: cleaned.text, isOn: instruction.isOn)
            )
        }
        return Array(kept.prefix(instructionLimit))
    }

    // MARK: - What the model is told

    /// The setup as prompt text, in the order that decides what wins.
    ///
    /// Safety first, then the boundaries, then the person's own rules, then
    /// the facts they approved. An instruction can shape how Maily writes; it
    /// can never widen what Maily is allowed to say or claim. That ordering
    /// is the whole safety model, so it is built here rather than assembled
    /// ad hoc at each call site.
    func briefing(now: Date = .now) -> String {
        guard config.isSetUp else { return "" }
        var parts: [String] = []

        if let persona = config.persona {
            parts.append("They are a \(persona.title.lowercased()).")
        }

        if !config.allowed.isEmpty {
            let list = AutoReplyConfig.Category.allCases
                .filter(config.allowed.contains)
                .map { "- \($0.title)" }
                .joined(separator: "\n")
            parts.append("You may answer these on their behalf:\n\(list)")
        }

        let boundaries = AutoReplyConfig.Boundary.allCases
            .filter(config.mustAsk.contains)
            .map { "- \($0.title)" }
            .joined(separator: "\n")
        if !boundaries.isEmpty {
            parts.append(
                "You may NOT answer any of these. They go back to the person, whatever else you have been told:\n\(boundaries)"
            )
        }

        let rules = config.activeInstructions.map { "- \($0.text)" }.joined(separator: "\n")
        if !rules.isEmpty {
            parts.append(
                """
                Their own rules for how you write. Follow them, unless one would break something above or would have you state a fact you were not given:
                \(rules)
                """
            )
        }

        let facts = config.business.filled.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")
        if !facts.isEmpty {
            parts.append(
                """
                The only facts you may state about their work. If an answer needs something that is not here, you do not have it:
                \(facts)
                """
            )
        }

        parts.append("When you are not sure: \(config.whenUnsure.title.lowercased()).")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Disk

    private func touch() {
        config.updatedAt = .now
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(AutoReplyConfig.self, from: data)
        else { return }
        config = stored
    }

    fileprivate func persistNow() { persist() }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(config)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // Losing this would mean asking them to teach Maily again, which
            // is bad enough to be worth knowing about -- but not worth
            // interrupting the setup they are in the middle of.
        }
    }
}

extension AutoReplyStore {

    /// Stops everything, at once.
    ///
    /// Off and back to drafting, in one call, because the person reaching for
    /// this is not in a mood to work out which of two switches does what.
    /// The setup survives -- panicking about one bad reply should not cost
    /// somebody the afternoon they spent teaching Maily their business.
    func stopEverything() {
        config.isOn = false
        config.mode = .draft
        config.updatedAt = .now
        persistNow()
    }
}
