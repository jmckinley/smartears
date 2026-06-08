import Foundation
import Combine

// MARK: - AlertMonitor (optional smart-alerting engine)
//
// HOW REAL INBOUND DELIVERY WORKS (and why this engine sits downstream):
//  * iOS apps CANNOT poll for new SMS/iMessage or Apple Mail. Inbound items reach
//    us through OS-mediated channels only:
//      - Notification Service Extension (UNNotificationServiceExtension): mutates
//        an incoming push BEFORE it's shown; can hand limited content to the app.
//      - Communication Notifications / Intents donation: richer sender metadata.
//      - BGTaskScheduler background fetch: periodically wakes us to pull from the
//        Gmail REST API (the one channel with full inbound bodies).
//      - User share / manual paste into the app.
//    The provenance of every item is captured by `InboundMessageSource`.
//  * THIS ENGINE IS A CONSUMER: those delivery mechanisms feed `EmailSummary` /
//    `MessageSummary` items into `ingest(...)`. The engine scores importance,
//    applies the user's `TriggerConfig` (VIPs, quiet hours, min importance), and
//    emits `AlertItem`s for the Voice layer to CHIME + SPEAK. It does no I/O and
//    fetches nothing itself — that separation keeps it testable and Sendable-safe.

/// Observable smart-alerting engine. Ingests inbound summaries, scores them, and
/// publishes `AlertItem`s that the Voice layer turns into a chime + spoken
/// summary. Pure decision logic — no networking, no polling.
@MainActor
public final class AlertMonitor: ObservableObject {

    // MARK: Published state (drives the optional SwiftUI surface)

    /// Alerts that passed the trigger, newest first. Surfaced for history review.
    @Published public private(set) var activeAlerts: [AlertItem] = []
    /// The most recent alert, if any (handy for a now-playing style banner).
    @Published public private(set) var latestAlert: AlertItem?

    // MARK: Configuration

    /// User-configurable trigger rules. Mutating this re-derives the scorer.
    public var triggerConfig: TriggerConfig {
        didSet { scorer = ImportanceScorer(config: .init(trigger: triggerConfig)) }
    }

    private var scorer: ImportanceScorer
    /// Optional LLM hook for refined scoring (nil = heuristic only).
    private let llmRanker: LLMImportanceRanking?
    /// Clock injection point for testable quiet-hours logic.
    private let now: @Sendable () -> Date

    // MARK: Event stream for downstream consumers (Voice layer)

    /// An async stream of emitted alerts. The Voice coordinator subscribes here
    /// to chime + speak. Buffered so a late subscriber still receives events.
    public let alertStream: AsyncStream<AlertItem>
    private let alertContinuation: AsyncStream<AlertItem>.Continuation

    // De-dup: avoid re-alerting the same source item twice.
    private var seenSourceIDs: Set<SmartEarsID> = []

    public init(
        triggerConfig: TriggerConfig = .default,
        llmRanker: LLMImportanceRanking? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.triggerConfig = triggerConfig
        self.scorer = ImportanceScorer(config: .init(trigger: triggerConfig))
        self.llmRanker = llmRanker
        self.now = now
        var continuation: AsyncStream<AlertItem>.Continuation!
        self.alertStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation = $0 }
        self.alertContinuation = continuation
    }

    deinit { alertContinuation.finish() }

    // MARK: Ingestion API (called by the delivery mechanisms described above)

    /// Ingest a batch of inbound emails. Returns the alerts that fired.
    @discardableResult
    public func ingest(emails: [EmailSummary]) async -> [AlertItem] {
        var fired: [AlertItem] = []
        for email in emails {
            if let alert = await evaluateEmail(email) { fired.append(alert) }
        }
        return fired
    }

    /// Ingest a batch of inbound messages. Returns the alerts that fired.
    @discardableResult
    public func ingest(messages: [MessageSummary]) async -> [AlertItem] {
        var fired: [AlertItem] = []
        for message in messages {
            if let alert = await evaluateMessage(message) { fired.append(alert) }
        }
        return fired
    }

    /// Mark an alert acknowledged (e.g. after it has been spoken / dismissed).
    public func acknowledge(_ alertID: SmartEarsID) {
        if let idx = activeAlerts.firstIndex(where: { $0.id == alertID }) {
            activeAlerts[idx].acknowledged = true
        }
        if latestAlert?.id == alertID { latestAlert?.acknowledged = true }
    }

    /// Clear all surfaced alerts (e.g. "catch me up" finished).
    public func clear() {
        activeAlerts.removeAll()
        latestAlert = nil
    }

    // MARK: Evaluation

    private func evaluateEmail(_ email: EmailSummary) async -> AlertItem? {
        guard !seenSourceIDs.contains(email.id) else { return nil }
        let raw = await scorer.refinedScore(
            sender: email.from,
            subject: email.subject,
            text: email.snippet ?? email.body,
            ranker: llmRanker
        )
        let importance = boostedImportance(scored: scorer.importance(for: raw), sender: email.from)
        guard shouldAlert(importance: importance, sender: email.from) else {
            seenSourceIDs.insert(email.id)
            return nil
        }
        let summary = spokenSummary(
            sender: email.from,
            headline: email.subject,
            detail: email.snippet ?? email.body
        )
        let alert = AlertItem(
            category: .email,
            title: "Email from \(email.from)",
            spokenSummary: summary,
            importance: importance,
            sourceMessageID: email.id
        )
        emit(alert, sourceID: email.id)
        return alert
    }

    private func evaluateMessage(_ message: MessageSummary) async -> AlertItem? {
        guard !seenSourceIDs.contains(message.id) else { return nil }
        let raw = await scorer.refinedScore(
            sender: message.senderName,
            subject: nil,
            text: message.preview ?? message.body,
            ranker: llmRanker
        )
        // Respect any importance already attached upstream (e.g. notification hint).
        let scored = max(scorer.importance(for: raw), message.importance)
        let importance = boostedImportance(scored: scored, sender: message.senderName)
        guard shouldAlert(importance: importance, sender: message.senderName) else {
            seenSourceIDs.insert(message.id)
            return nil
        }
        let summary = spokenSummary(
            sender: message.senderName,
            headline: nil,
            detail: message.preview ?? message.body
        )
        let alert = AlertItem(
            category: .message,
            title: "Message from \(message.senderName)",
            spokenSummary: summary,
            importance: importance,
            sourceMessageID: message.id
        )
        emit(alert, sourceID: message.id)
        return alert
    }

    // MARK: Trigger rules

    /// VIP senders always alert at least `.high`, regardless of content score.
    private func boostedImportance(scored: Importance, sender: String) -> Importance {
        guard isVIP(sender) else { return scored }
        return max(scored, .high)
    }

    private func isVIP(_ sender: String) -> Bool {
        let lowered = sender.lowercased()
        return triggerConfig.vipSenders.contains { vip in
            let v = vip.lowercased()
            return !v.isEmpty && (lowered.contains(v) || v.contains(lowered))
        }
    }

    /// Applies min-importance + quiet-hours. VIPs bypass quiet hours.
    private func shouldAlert(importance: Importance, sender: String) -> Bool {
        guard importance >= triggerConfig.minimumImportance else { return false }
        if isInQuietHours(), !isVIP(sender), importance < .urgent {
            // During quiet hours, only urgent items (or VIPs) break through.
            return false
        }
        return true
    }

    private func isInQuietHours() -> Bool {
        guard let start = triggerConfig.quietHoursStart,
              let end = triggerConfig.quietHoursEnd else { return false }
        let hour = Calendar.current.component(.hour, from: now())
        if start == end { return false }
        if start < end {
            return hour >= start && hour < end
        } else {
            // Overnight window, e.g. 22 -> 7.
            return hour >= start || hour < end
        }
    }

    // MARK: Emission + spoken text

    private func emit(_ alert: AlertItem, sourceID: SmartEarsID) {
        seenSourceIDs.insert(sourceID)
        activeAlerts.insert(alert, at: 0)
        latestAlert = alert
        alertContinuation.yield(alert)
    }

    /// Builds a concise spoken summary. Honors `readFullBody`: when off, we speak
    /// only a short preview to keep the audio surface glanceable.
    private func spokenSummary(sender: String, headline: String?, detail: String?) -> String {
        var parts: [String] = []
        if let headline, !headline.isEmpty { parts.append(headline) }
        if let detail, !detail.isEmpty {
            let body = triggerConfig.readFullBody ? detail : preview(of: detail)
            parts.append(body)
        }
        let content = parts.joined(separator: ". ")
        return content.isEmpty ? "New item from \(sender)." : "\(sender): \(content)"
    }

    /// First sentence (or ~120 chars) for a glanceable spoken preview.
    private func preview(of text: String, limit: Int = 120) -> String {
        if let dot = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let sentence = String(text[..<dot])
            if sentence.count <= limit { return sentence }
        }
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
