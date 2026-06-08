//
//  VoiceSessionManager.swift
//  SmartEars — Voice layer
//
//  Orchestrates the always-on voice turn as an `ObservableObject` SwiftUI can
//  bind to. It drives the `VoiceSessionState` machine (Models.swift):
//
//      idle ──(wake word / AirPod activation)──▶ waking (chime)
//        ▲                                          │
//        │                                          ▼
//        └────────────── speaking ◀── thinking ◀── listening (STT, stop-on-silence)
//                            │                          ▲
//                            ▼                          │
//                     awaitingFollowUp ─────────────────┘
//                     (mic re-opens briefly WITHOUT re-triggering the wake word)
//
//  It ties together the four Voice services:
//    * WakeWordEngine      — detects the trigger phrase (or AirPod activation).
//    * SpeechRecognizing   — captures the user's utterance (one at a time).
//    * SpeechSynthesizing  — speaks the assistant's response (barge-in capable).
//    * GestureService      — AirPod input (single-press wake, removal -> stop).
//
//  Recognized user utterances are handed to the assistant via the injected
//  `onUtterance` closure (the AssistantEngine boundary), which returns an
//  `AssistantResponse`. `followUpExpected` keeps the conversation going without
//  re-triggering the wake word (Meta/Gemini-style contextual follow-ups).
//

import Foundation
import SwiftUI

/// Tunables for the session state machine.
public struct VoiceSessionConfig: Sendable {
    /// How long the mic stays open after a response for a contextual follow-up.
    public var followUpWindowSeconds: TimeInterval
    /// Whether an AirPod single-press should wake the assistant (no wake word).
    public var wakeOnAirPodPress: Bool
    /// Whether removing a bud stops in-progress speech and returns to idle.
    public var stopOnEarBudRemoval: Bool

    public init(
        followUpWindowSeconds: TimeInterval = 6,
        wakeOnAirPodPress: Bool = true,
        stopOnEarBudRemoval: Bool = true
    ) {
        self.followUpWindowSeconds = followUpWindowSeconds
        self.wakeOnAirPodPress = wakeOnAirPodPress
        self.stopOnEarBudRemoval = stopOnEarBudRemoval
    }

    public static let `default` = VoiceSessionConfig()
}

/// Orchestrates the hands-free voice loop and publishes observable state for the
/// minimal SwiftUI surface. Main-actor isolated because it mutates `@Published`
/// UI state and coordinates audio.
@MainActor
public final class VoiceSessionManager: ObservableObject {

    // MARK: Published UI state

    /// Current point in the voice state machine.
    @Published public private(set) var state: VoiceSessionState = .idle
    /// The live (partial) transcript while listening; cleared between turns.
    @Published public private(set) var liveTranscript: String = ""
    /// The most recent assistant response (drives the optional display card).
    @Published public private(set) var lastResponse: AssistantResponse?
    /// True when the wake-word engine is actively listening for the trigger.
    @Published public private(set) var isWakeListening: Bool = false
    /// A user-facing error from the voice pipeline (e.g. speech permission was
    /// revoked). The UI binds this to show an alert instead of the session
    /// appearing to silently die. Cleared at the start of each turn.
    @Published public private(set) var lastError: SmartEarsError?

    // MARK: Dependencies

    private let wakeWord: WakeWordEngine
    private let recognizer: SpeechRecognizing
    private let synthesizer: SpeechSynthesizing
    private let gestures: GestureService?
    private let chime: ChimeService?
    private let config: VoiceSessionConfig

    /// The assistant boundary: a recognized utterance in -> a response out.
    /// Injected so the Voice layer doesn't depend on the Assistant module.
    private let onUtterance: @Sendable (String) async -> AssistantResponse

    // MARK: Internal tasks

    private var wakeTask: Task<Void, Never>?
    private var gestureTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?

    public init(
        wakeWord: WakeWordEngine,
        recognizer: SpeechRecognizing,
        synthesizer: SpeechSynthesizing,
        gestures: GestureService? = nil,
        chime: ChimeService? = nil,
        config: VoiceSessionConfig = .default,
        onUtterance: @escaping @Sendable (String) async -> AssistantResponse
    ) {
        self.wakeWord = wakeWord
        self.recognizer = recognizer
        self.synthesizer = synthesizer
        self.gestures = gestures
        self.chime = chime
        self.config = config
        self.onUtterance = onUtterance
    }

    // MARK: Lifecycle

    /// Begins listening for the wake word (and AirPod activation, if enabled).
    /// Call once when the assistant should go "always on".
    public func start() {
        guard wakeTask == nil else { return }
        isWakeListening = true
        state = .idle

        let events = wakeWord.wakeEvents()
        wakeTask = Task { [weak self] in
            for await _ in events {
                guard let self else { return }
                await self.handleWake()
            }
            await MainActor.run { self?.isWakeListening = false }
        }

        if let gestures {
            gestureTask = Task { [weak self] in
                for await event in gestures.gestureEvents() {
                    guard let self else { return }
                    await self.handleGesture(event)
                }
            }
        }
    }

    /// Stops all listening and speaking, returning to idle.
    public func stop() {
        wakeTask?.cancel(); wakeTask = nil
        gestureTask?.cancel(); gestureTask = nil
        turnTask?.cancel(); turnTask = nil
        isWakeListening = false
        Task { await synthesizer.stop() }
        state = .idle
        liveTranscript = ""
    }

    /// Manual wake (e.g. a tap in the UI) — same path as the wake word.
    public func wakeManually() {
        Task { await handleWake() }
    }

    // MARK: Wake & gestures

    private func handleWake() async {
        // Ignore wake re-triggers while a turn is already in flight.
        guard state == .idle || state == .awaitingFollowUp else { return }
        startTurn(playWakeChime: true)
    }

    private func handleGesture(_ event: GestureEvent) async {
        switch event.gesture {
        case .singlePress where config.wakeOnAirPodPress:
            await handleWake()
        case .earBudRemoved where config.stopOnEarBudRemoval:
            // Auto-pause/stop on removal: barge-in any speech and reset.
            await synthesizer.stop()
            turnTask?.cancel(); turnTask = nil
            state = .idle
            liveTranscript = ""
        default:
            break
        }
    }

    // MARK: Turn execution

    /// Runs one full turn: chime -> listen -> think -> speak, then optionally
    /// loops into a follow-up window without requiring the wake word again.
    private func startTurn(playWakeChime: Bool) {
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(playWakeChime: playWakeChime)
        }
    }

    private func runTurn(playWakeChime: Bool) async {
        // 1) Waking — play the wake chime (if provided) so the user knows we're up.
        state = .waking
        liveTranscript = ""
        lastError = nil
        if playWakeChime { await chime?.playWakeChime() }

        // 2) Listening — capture one utterance (recognizer handles stop-on-silence
        //    and the max-utterance cap internally).
        state = .listening
        let outcome = await captureUtterance()

        if Task.isCancelled { state = .idle; return }

        let utterance: String
        switch outcome {
        case .heard(let text):
            utterance = text
        case .nothing:
            // Nothing heard — return to idle (do NOT keep the mic open).
            state = .idle
            liveTranscript = ""
            return
        case .failed(let error):
            // A hard failure (e.g. revoked speech permission). Surface it to the
            // UI so the user isn't left with a silently dead session.
            handleCaptureFailure(error)
            return
        }

        guard !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing heard — return to idle (do NOT keep the mic open).
            state = .idle
            liveTranscript = ""
            return
        }

        // 3) Thinking — hand the utterance to the assistant.
        state = .thinking
        let response = await onUtterance(utterance)
        lastResponse = response

        if Task.isCancelled { state = .idle; return }

        // 4) Speaking — TTS is the primary output (barge-in capable via stop()).
        state = .speaking
        await synthesizer.speak(response.spokenText)

        if Task.isCancelled { state = .idle; return }

        // 5) Follow-up — if the response expects one, keep the mic open briefly
        //    WITHOUT re-triggering the wake word.
        if response.followUpExpected {
            await runFollowUp()
        } else {
            state = .idle
            liveTranscript = ""
        }
    }

    /// Outcome of one capture attempt: distinguishes "nothing heard" from a hard
    /// failure (e.g. revoked speech permission) so the state machine can surface
    /// the latter to the user instead of silently going idle.
    private enum CaptureOutcome {
        case heard(String)
        case nothing
        case failed(SmartEarsError)
    }

    /// Captures a single utterance, updating `liveTranscript` with partials and
    /// returning the final text (or the best partial seen). A thrown
    /// `SmartEarsError` (e.g. `.permissionDenied`) is reported as `.failed` so
    /// the caller can notify the user rather than treating it as silence.
    private func captureUtterance() async -> CaptureOutcome {
        var finalText: String?
        do {
            for try await transcription in recognizer.transcribe() {
                if Task.isCancelled { break }
                liveTranscript = transcription.text
                if transcription.isFinal {
                    finalText = transcription.text
                } else if finalText == nil {
                    finalText = transcription.text // best-so-far fallback
                }
            }
        } catch let error as SmartEarsError {
            // A real failure (permission revoked, recognizer unavailable) — do
            // NOT treat as silence. Surface it so the UI can explain the dead end.
            return .failed(error)
        } catch {
            // Unknown transport error — wrap it so the caller can still react.
            return .failed(.other(error.localizedDescription))
        }
        guard let finalText else { return .nothing }
        return .heard(finalText)
    }

    /// The contextual follow-up window: opens the mic again for a short time. If
    /// the user speaks, we run another turn (no wake chime, no wake word). If the
    /// window elapses silently, we return to idle.
    private func runFollowUp() async {
        state = .awaitingFollowUp
        liveTranscript = ""

        // Race the follow-up capture against the window timeout.
        let windowNanos = UInt64(config.followUpWindowSeconds * 1_000_000_000)

        let captured: CaptureOutcome = await withTaskGroup(of: CaptureOutcome.self) { group in
            group.addTask { [weak self] in
                guard let self else { return .nothing }
                return await self.captureUtterance()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: windowNanos)
                return .nothing // timeout sentinel
            }
            let first = await group.next() ?? .nothing
            group.cancelAll()
            return first
        }

        switch captured {
        case .heard(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            // Treat as a new turn in the same conversation (no chime).
            await runTurn(playWakeChime: false)
        case .failed(let error):
            // Surface a hard failure (e.g. revoked permission) instead of silently
            // dropping back to idle.
            handleCaptureFailure(error)
        case .heard, .nothing:
            state = .idle
            liveTranscript = ""
        }
    }

    /// Records a capture failure for the UI and returns the machine to idle. The
    /// `lastError` publish drives a user-facing alert so a revoked permission no
    /// longer leaves the session appearing dead with no explanation.
    private func handleCaptureFailure(_ error: SmartEarsError) {
        lastError = error
        state = .idle
        liveTranscript = ""
    }

    /// Dismiss the current voice error (e.g. after the user acknowledges the alert).
    public func clearError() {
        lastError = nil
    }
}
