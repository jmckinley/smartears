import Foundation

// MARK: - ImportanceScorer (COMMS / Alerting layer)
//
// A lightweight, deterministic heuristic that rates the importance of an inbound
// email/message on a 0...1 scale. It combines three signals:
//   1. VIP senders   — exact/contains match against a configured VIP list.
//   2. Urgency keywords — "urgent", "asap", "emergency", etc. in subject/body.
//   3. Structural cues — unread flag, question marks, all-caps shouting.
//
// The scorer is intentionally pure + Sendable so it can run anywhere (background
// fetch, Notification Service Extension, main actor) with no side effects.
//
// An OPTIONAL async LLM hook (`LLMImportanceRanking`) lets callers refine the
// score with a model when one is configured; with no LLM the heuristic stands
// alone, so the app works with no secrets.

/// Optional async hook to let an LLM refine a heuristic importance score.
/// Implementations should return a 0...1 value. Kept separate from `LLMService`
/// so the scorer has no hard dependency on the Assistant module.
public protocol LLMImportanceRanking: Sendable {
    /// Returns a refined importance score in 0...1 for the given text context.
    func rankImportance(subject: String?, sender: String, text: String?) async -> Double
}

/// Deterministic importance heuristic with an optional LLM refinement hook.
public struct ImportanceScorer: Sendable {
    /// Configuration mirrors the user-facing `TriggerConfig` knobs.
    public struct Config: Sendable {
        public var vipSenders: [String]
        public var urgentKeywords: [String]
        /// Weight blend (must be applied to bounded signals; clamped to 0...1).
        public var vipWeight: Double
        public var keywordWeight: Double
        public var structuralWeight: Double

        public init(
            vipSenders: [String] = [],
            urgentKeywords: [String] = ["urgent", "asap", "emergency", "911", "immediately", "deadline"],
            vipWeight: Double = 0.6,
            keywordWeight: Double = 0.5,
            structuralWeight: Double = 0.2
        ) {
            self.vipSenders = vipSenders
            self.urgentKeywords = urgentKeywords
            self.vipWeight = vipWeight
            self.keywordWeight = keywordWeight
            self.structuralWeight = structuralWeight
        }

        /// Builds a scorer config from the user's persisted `TriggerConfig`.
        public init(trigger: TriggerConfig) {
            self.init(vipSenders: trigger.vipSenders, urgentKeywords: trigger.urgentKeywords)
        }
    }

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: Public scoring API

    /// Heuristic 0...1 importance for an email.
    public func scoreEmail(from: String, subject: String?, snippet: String?) -> Double {
        score(sender: from, subject: subject, text: snippet)
    }

    /// Heuristic 0...1 importance for a message.
    public func scoreMessage(from: String, body: String?) -> Double {
        score(sender: from, subject: nil, text: body)
    }

    /// Convenience: score an existing `EmailSummary`.
    public func score(_ email: EmailSummary) -> Double {
        scoreEmail(from: email.from, subject: email.subject, snippet: email.snippet ?? email.body)
    }

    /// Convenience: score an existing `MessageSummary`.
    public func score(_ message: MessageSummary) -> Double {
        scoreMessage(from: message.senderName, body: message.preview ?? message.body)
    }

    /// Optional LLM-refined score. Blends the heuristic with the model output.
    /// Falls back to the heuristic alone if `ranker` is nil.
    public func refinedScore(
        sender: String,
        subject: String?,
        text: String?,
        ranker: LLMImportanceRanking?
    ) async -> Double {
        let heuristic = score(sender: sender, subject: subject, text: text)
        guard let ranker else { return heuristic }
        let llm = await ranker.rankImportance(subject: subject, sender: sender, text: text)
        // Weighted blend: trust the model a bit more, but never ignore heuristics.
        return clamp(0.4 * heuristic + 0.6 * clamp(llm))
    }

    /// Maps a 0...1 score onto the discrete `Importance` enum used everywhere.
    public func importance(for score: Double) -> Importance {
        switch clamp(score) {
        case 0.85...:      return .urgent
        case 0.6..<0.85:   return .high
        case 0.3..<0.6:    return .normal
        default:           return .low
        }
    }

    // MARK: Core heuristic

    private func score(sender: String, subject: String?, text: String?) -> Double {
        let haystack = [subject, text].compactMap { $0 }.joined(separator: " ").lowercased()

        var total = 0.0

        // 1. VIP sender signal.
        if isVIP(sender) {
            total += config.vipWeight
        }

        // 2. Urgency keyword signal (scaled by how many distinct hits).
        let hits = config.urgentKeywords.reduce(into: 0) { acc, kw in
            if haystack.contains(kw.lowercased()) { acc += 1 }
        }
        if hits > 0 {
            // First hit gives full keyword weight; extra hits add diminishing bonus.
            total += config.keywordWeight + min(Double(hits - 1) * 0.1, 0.2)
        }

        // 3. Structural cues (questions asked, shouting, explicit "?" requests).
        total += structuralSignal(subject: subject, text: text) * config.structuralWeight

        return clamp(total)
    }

    private func isVIP(_ sender: String) -> Bool {
        // Match a VIP entry against the sender using the entry's shape, so we
        // avoid the false positives of a naive bidirectional `contains`
        // (e.g. VIP "john" must NOT match "johnson@example.com"):
        //   • "name@host.com"  → exact email match
        //   • "host.com"       → sender's email domain match (incl. subdomains)
        //   • "john" / "Jane"  → whole-token match against the sender's words
        let lowered = sender.lowercased()
        let email = Self.extractEmail(from: lowered)
        let domain = email?.split(separator: "@").last.map(String.init)
        let tokens = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        return config.vipSenders.contains { vip in
            let v = vip.lowercased().trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return false }
            if v.contains("@") {                       // full email → exact match
                return email == v
            }
            if v.contains(".") {                       // domain → domain/subdomain match
                guard let domain else { return false }
                return domain == v || domain.hasSuffix("." + v)
            }
            return tokens.contains(v) || email == v    // bare name → whole-token match
        }
    }

    /// Extracts the first email-looking token from a raw sender string such as
    /// `"Jane Doe <jane@example.com>"`, returning `jane@example.com` (or nil).
    private static func extractEmail(from sender: String) -> String? {
        sender
            .split { " <>,;\"".contains($0) }
            .map(String.init)
            .first { $0.contains("@") }
    }

    /// Returns a 0...1 structural-urgency hint (capped before weighting).
    private func structuralSignal(subject: String?, text: String?) -> Double {
        var signal = 0.0
        let combined = [subject, text].compactMap { $0 }.joined(separator: " ")
        guard !combined.isEmpty else { return 0 }

        // A direct question often expects a reply.
        if combined.contains("?") { signal += 0.4 }

        // SHOUTING (high ratio of uppercase letters) reads as urgent.
        let letters = combined.filter { $0.isLetter }
        if letters.count >= 6 {
            let uppercase = letters.filter { $0.isUppercase }.count
            let ratio = Double(uppercase) / Double(letters.count)
            if ratio > 0.6 { signal += 0.4 }
        }

        // Exclamation emphasis.
        if combined.contains("!!") { signal += 0.2 }

        return min(signal, 1.0)
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0.0), 1.0) }
}
