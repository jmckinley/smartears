import Foundation
import SwiftUI

// MARK: - ConversationManager (Assistant AI layer)
//
// An `ObservableObject` that owns the conversation history and drives a full
// assistant turn: take a user utterance -> route it through the
// `AssistantToolRouter` (on-device classification first, LLM fallback) -> obtain
// an `AssistantResponse` -> publish it for the SwiftUI surface and hand its
// `spokenText` to the TTS layer.
//
// It also supports two follow-up patterns highlighted in the architecture:
//   * Contextual follow-ups (Meta-style): when a response's `followUpExpected`
//     is true, the mic should stay open WITHOUT re-triggering the wake word.
//     `awaitingFollowUp` exposes that to the Voice layer.
//   * Send confirmation: when a response carries a `PendingConfirmation`, the
//     manager holds it and resolves a subsequent "yes / no / change" turn.
//
// The Voice layer (SpeechSynthesizing) is injected as a protocol so the manager
// stays testable and free of AVFoundation. NO secrets here.

@MainActor
public final class ConversationManager: ObservableObject {

    // MARK: Published state (drives the minimal SwiftUI surface)

    /// Chronological transcript of the dialogue (oldest first).
    @Published public private(set) var turns: [ConversationTurn] = []

    /// The most recent assistant response (for now-playing / glanceable UI).
    @Published public private(set) var latestResponse: AssistantResponse?

    /// True while a turn is being processed (route + LLM + speak).
    @Published public private(set) var isProcessing: Bool = false

    /// True when the assistant expects an immediate follow-up and the Voice layer
    /// should keep the mic open without re-triggering the wake word.
    @Published public private(set) var awaitingFollowUp: Bool = false

    /// A confirmable side effect awaiting "yes / no / change".
    @Published public private(set) var pendingConfirmation: PendingConfirmation?

    // MARK: Dependencies (all protocols — swappable for mocks)

    private let router: AssistantToolRouter
    private let speaker: SpeechSynthesizing
    /// Performs the actual send once a PendingConfirmation is approved.
    private let sendExecutor: SendExecuting

    /// Rolling context window handed to the LLM for conversational coherence.
    private var contextWindow: [String] = []
    private let maxContextEntries = 8

    public init(
        router: AssistantToolRouter,
        speaker: SpeechSynthesizing,
        sendExecutor: SendExecuting
    ) {
        self.router = router
        self.speaker = speaker
        self.sendExecutor = sendExecutor
    }

    // MARK: - Public API

    /// Handle one user utterance end-to-end. Resolves any pending confirmation
    /// first (yes / no / change), otherwise routes the utterance normally.
    public func submit(utterance: String) async {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // If we're awaiting a send confirmation, interpret yes/no/change here.
        if let pending = pendingConfirmation {
            await resolveConfirmation(reply: trimmed, pending: pending)
            return
        }

        // Capture the prior conversation context BEFORE appending this turn, so
        // the LLM receives history without the current utterance duplicated in it.
        let priorContext = contextWindow

        appendUserTurn(trimmed)
        isProcessing = true
        awaitingFollowUp = false

        let response = await router.handle(utterance: trimmed, context: priorContext)
        await present(response)

        isProcessing = false
    }

    /// Route an already-parsed intent (e.g. from a tapped quick-action or gesture)
    /// rather than free text.
    public func submit(intent: AssistantIntent) async {
        isProcessing = true
        awaitingFollowUp = false
        let response = await router.route(intent, context: contextWindow)
        await present(response)
        isProcessing = false
    }

    /// Speak the last assistant response again ("repeat that").
    public func repeatLast() async {
        guard let text = latestResponse?.spokenText, !text.isEmpty else { return }
        await speaker.speak(text)
    }

    /// Stop any in-progress speech and clear the follow-up window.
    public func stop() async {
        await speaker.stop()
        awaitingFollowUp = false
    }

    /// Clear the entire conversation (history screen "clear" action).
    public func clear() {
        turns.removeAll()
        latestResponse = nil
        contextWindow.removeAll()
        pendingConfirmation = nil
        awaitingFollowUp = false
    }

    // MARK: - Turn presentation

    /// Publishes a response, appends it to history, manages the follow-up window
    /// and any pending confirmation, and speaks it.
    private func present(_ response: AssistantResponse) async {
        latestResponse = response
        pendingConfirmation = response.pendingConfirmation
        appendAssistantTurn(response)

        // A pending confirmation implicitly keeps the mic open for yes/no/change.
        awaitingFollowUp = response.followUpExpected || response.pendingConfirmation != nil

        if !response.spokenText.isEmpty {
            await speaker.speak(response.spokenText)
        }
    }

    // MARK: - Send confirmation flow

    /// Resolve a yes/no/change reply against a held `PendingConfirmation`.
    private func resolveConfirmation(reply: String, pending: PendingConfirmation) async {
        appendUserTurn(reply)
        let answer = reply.lowercased()

        // Affirmative -> execute the side effect.
        if isAffirmative(answer) {
            pendingConfirmation = nil
            await executeSend(pending.action)
            return
        }

        // "change" / "edit" -> discard and re-open for a new instruction.
        if answer.contains("change") || answer.contains("edit") || answer.contains("redo") {
            pendingConfirmation = nil
            await present(AssistantResponse(
                spokenText: "Okay, what would you like to change?",
                followUpExpected: true
            ))
            return
        }

        // Negative / anything else -> cancel.
        if isNegative(answer) {
            pendingConfirmation = nil
            await present(AssistantResponse(spokenText: "Okay, I won't send it."))
            return
        }

        // Ambiguous — ask again, keeping the confirmation alive.
        await present(AssistantResponse(
            spokenText: "Sorry, should I send it? Say yes, no, or change.",
            followUpExpected: true,
            pendingConfirmation: pending
        ))
    }

    /// Perform the approved send via the injected executor and report the result.
    private func executeSend(_ action: PendingConfirmation.Action) async {
        do {
            try await sendExecutor.execute(action)
            // SMS/iMessage/Apple Mail return successfully here only once the user
            // has tapped Send in the system compose sheet (the executor surfaces
            // `userActionRequired` until then — see below).
            await present(AssistantResponse(spokenText: "Sent."))
        } catch let error as SmartEarsError {
            switch error {
            case .userActionRequired(let message):
                // Honest Apple-platform reality: SMS/iMessage and Apple Mail
                // cannot be auto-sent. The compose sheet is up; the user must tap
                // Send. We narrate that instead of claiming we sent it.
                await present(AssistantResponse(
                    spokenText: message.isEmpty
                        ? "I've opened it for you — just tap Send to finish."
                        : message
                ))
            default:
                await present(AssistantResponse(
                    spokenText: "I couldn't send that. \(error.errorDescription ?? "")"
                ))
            }
        } catch {
            await present(AssistantResponse(spokenText: "I couldn't send that just now."))
        }
    }

    private func isAffirmative(_ text: String) -> Bool {
        ["yes", "yeah", "yep", "yup", "sure", "send it", "send", "do it", "go ahead", "confirm", "ok", "okay"]
            .contains { text == $0 || text.contains($0) }
    }

    private func isNegative(_ text: String) -> Bool {
        ["no", "nope", "nah", "cancel", "never mind", "nevermind", "don't", "stop", "forget it"]
            .contains { text == $0 || text.contains($0) }
    }

    // MARK: - History + context bookkeeping

    private func appendUserTurn(_ text: String) {
        turns.append(ConversationTurn(role: .user, text: text))
        pushContext("User: \(text)")
    }

    private func appendAssistantTurn(_ response: AssistantResponse) {
        turns.append(ConversationTurn(
            role: .assistant,
            text: response.spokenText,
            card: response.displayCard
        ))
        if !response.spokenText.isEmpty {
            pushContext("Assistant: \(response.spokenText)")
        }
    }

    private func pushContext(_ entry: String) {
        contextWindow.append(entry)
        if contextWindow.count > maxContextEntries {
            contextWindow.removeFirst(contextWindow.count - maxContextEntries)
        }
    }
}

// MARK: - Conversation Turn (history record)

/// One entry in the conversation transcript, suitable for the history UI.
public struct ConversationTurn: Identifiable, Sendable, Equatable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }
    public let id: SmartEarsID
    public let role: Role
    public let text: String
    public let card: DisplayCard?
    public let createdAt: Date

    public init(
        id: SmartEarsID = UUID(),
        role: Role,
        text: String,
        card: DisplayCard? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.card = card
        self.createdAt = createdAt
    }

    // Equatable conformance ignores the non-Equatable DisplayCard payload and
    // compares identity + content fields, which is all the UI needs.
    public static func == (lhs: ConversationTurn, rhs: ConversationTurn) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role && lhs.text == rhs.text
    }
}

// MARK: - Send Executor boundary

/// Executes an approved `PendingConfirmation.Action` against the Comms layer.
/// Kept as a protocol so the manager depends only on this boundary, not on the
/// concrete MessageUI / Gmail implementations.
///
/// Implementations that wrap MFMessageComposeViewController / MFMailComposeViewController
/// should throw `SmartEarsError.userActionRequired` because the user must tap
/// Send — there is no public auto-send API for SMS/iMessage or Apple Mail.
public protocol SendExecuting: Sendable {
    func execute(_ action: PendingConfirmation.Action) async throws
}

/// A default executor that bridges to the Comms protocols. It is provided here
/// for convenience/wiring; the App layer's ServiceFactory injects the real one.
public struct DefaultSendExecutor: SendExecuting {
    private let messageCompose: MessageComposeService
    private let email: EmailService

    public init(messageCompose: MessageComposeService, email: EmailService) {
        self.messageCompose = messageCompose
        self.email = email
    }

    public func execute(_ action: PendingConfirmation.Action) async throws {
        switch action {
        case let .sendMessage(channel, recipient, body):
            // Compose-only: surfaces userActionRequired (user taps Send).
            try await messageCompose.compose(channel: channel, recipient: recipient, body: body)
        case let .sendEmail(recipient, subject, body):
            // Gmail API sends directly; MailCompose path surfaces userActionRequired.
            try await email.sendEmail(recipient: recipient, subject: subject, body: body)
        }
    }
}
