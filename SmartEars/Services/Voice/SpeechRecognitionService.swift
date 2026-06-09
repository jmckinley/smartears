//
//  SpeechRecognitionService.swift
//  SmartEars — Voice layer
//
//  Continuous, on-device speech-to-text built on `SFSpeechRecognizer` + an
//  `AVAudioEngine` input tap. This is the STT half of the always-on voice
//  pipeline (wake-word -> STT -> intent -> TTS).
//
//  Apple-platform reality checks honestly reflected here:
//   * `SFSpeechRecognizer` requires BOTH a microphone-usage and a
//     speech-recognition-usage authorization (Info.plist: NSMicrophoneUsageDescription
//     and NSSpeechRecognitionUsageDescription). We request them explicitly.
//   * On-device recognition (`requiresOnDeviceRecognition = true`) avoids sending
//     audio to Apple's servers and works offline, but is only available when the
//     recognizer reports `supportsOnDeviceRecognition`. We fall back to server
//     recognition only if on-device is unavailable.
//   * There is NO truly "always-on, zero-cost" recognition API for third parties
//     the way first-party "Hey Siri" works; we run a real audio tap, which has a
//     battery cost. Endpointing (stop-on-silence) and a max-utterance cap keep
//     each recognition session bounded.
//

import Foundation
import Speech
import AVFoundation

// MARK: - Tunables

/// Endpointing / capping parameters for a single recognition session.
public struct SpeechRecognitionTuning: Sendable {
    /// Stop the utterance after this much trailing silence (no new partial text).
    public var endpointSilenceSeconds: TimeInterval
    /// Hard cap on a single utterance so a stuck session can't run forever.
    public var maxUtteranceSeconds: TimeInterval
    /// Prefer on-device recognition when the recognizer supports it.
    public var preferOnDevice: Bool

    public init(
        endpointSilenceSeconds: TimeInterval = 1.5,
        maxUtteranceSeconds: TimeInterval = 30,
        preferOnDevice: Bool = true
    ) {
        self.endpointSilenceSeconds = endpointSilenceSeconds
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.preferOnDevice = preferOnDevice
    }

    public static let `default` = SpeechRecognitionTuning()
}

// MARK: - Permissions helper

/// Centralized permission requests for the voice pipeline. Both speech and
/// microphone authorization are required before any recognition can run.
public enum SpeechPermissions {
    /// Requests speech-recognition authorization. Returns true if granted.
    public static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Requests microphone (record) permission. Returns true if granted.
    public static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            // AVAudioApplication is the iOS 17+ surface; AVAudioSession's
            // requestRecordPermission is deprecated there.
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Convenience: both must be granted for recognition to function.
    public static func requestAll() async -> Bool {
        async let speech = requestSpeechAuthorization()
        async let mic = requestMicrophoneAuthorization()
        let speechGranted = await speech
        let micGranted = await mic
        return speechGranted && micGranted
    }
}

// MARK: - Live implementation

/// Live STT using `SFSpeechRecognizer` over an `AVAudioEngine` input tap.
///
/// Conforms to `SpeechRecognizing` (defined in Models.swift). Each call to
/// `transcribe()` runs ONE utterance: it streams partial `Transcription` values
/// and finishes on trailing silence, the max-utterance cap, or a final result.
///
/// The type is an `actor` so the engine/request/task lifecycle is serialized and
/// safe to use from Swift Concurrency call sites.
public actor LiveSpeechRecognitionService: SpeechRecognizing {

    private let recognizer: SFSpeechRecognizer?
    private let tuning: SpeechRecognitionTuning
    private let audioEngine = AVAudioEngine()

    /// In-flight request/task for the current utterance (one at a time).
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Timestamp of the most recent partial result, used for silence endpointing.
    /// Lives in actor state so it is only read/written on the actor executor
    /// (the recognition callback hops onto the actor before touching it).
    private var lastUpdate = Date()
    /// Whether a recognition session is currently active. Guards against the
    /// continuation being finished or torn down more than once.
    private var sessionActive = false
    /// Watches the AudioSessionController for an interruption so we can fail-fast
    /// this utterance (call/Siri/alarm) instead of wedging the for-await loop.
    private var interruptionTask: Task<Void, Never>?

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        tuning: SpeechRecognitionTuning = .default
    ) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.tuning = tuning
    }

    /// Streams transcriptions for a single utterance. Ends on silence, the
    /// max-utterance cap, an error, or a final SFSpeech result.
    nonisolated public func transcribe() -> AsyncThrowingStream<Transcription, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.start(continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task { await self.teardown() }
            }
        }
    }

    // MARK: Session lifecycle

    private func start(continuation: AsyncThrowingStream<Transcription, Error>.Continuation) async {
        guard let recognizer, recognizer.isAvailable else {
            continuation.finish(throwing: SmartEarsError.unsupported("Speech recognizer unavailable for this locale/device."))
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            continuation.finish(throwing: SmartEarsError.permissionDenied("Speech recognition not authorized."))
            return
        }

        // Defensive reset: if a prior utterance's engine/tap/request wasn't fully
        // cleaned up (e.g. a second transcribe() arrives before the first stream
        // terminated), tear it down before reusing the shared AVAudioEngine.
        // Reusing a still-running engine makes prepare()/start() throw.
        teardown()
        sessionActive = true

        // Configure the shared audio session for measurement-quality capture via
        // the single session owner (drops the contradictory/moot options).
        do {
            try await AudioSessionController.shared.configureForCapture()
        } catch {
            finish(continuation: continuation, error: SmartEarsError.other("Audio session setup failed: \(error.localizedDescription)"))
            return
        }

        // Fail-fast this utterance if the OS interrupts us (call/Siri/alarm).
        // Without this the for-await loop in RootView wedges forever.
        interruptionTask = Task { [weak self] in
            guard let self else { return }
            for await event in await AudioSessionController.shared.events() {
                if case .interruptionBegan = event {
                    await self.finish(continuation: continuation, error: SmartEarsError.other("Audio interrupted."))
                    return
                }
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if tuning.preferOnDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        // Endpointing + cap timers, driven off the main session clock.
        let silenceCap = tuning.endpointSilenceSeconds
        let hardCap = tuning.maxUtteranceSeconds
        self.lastUpdate = Date()
        let startedAt = Date()

        // The recognitionTask callback fires on SFSpeechRecognizer's internal
        // background queue. AsyncThrowingStream.Continuation is NOT thread-safe,
        // so we MUST NOT yield/finish from that background thread while the
        // consumer iterates on another executor. Hop onto the actor first so all
        // continuation access (and the lastUpdate/teardown state) is serialized
        // on the actor's executor.
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Snapshot the Sendable values we need; SFSpeechRecognitionResult is
            // not Sendable, so extract before hopping to the actor.
            let payload: Transcription? = result.map {
                Transcription(
                    text: $0.bestTranscription.formattedString,
                    isFinal: $0.isFinal,
                    confidence: $0.bestTranscription.segments.last?.confidence ?? 1.0
                )
            }
            let errorMessage = error?.localizedDescription
            Task { await self.handleRecognition(payload: payload, errorMessage: errorMessage, continuation: continuation) }
        }

        // Install the input tap and start the engine.
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat: AVAudioFormat
        if hwFormat.channelCount > 0, hwFormat.sampleRate > 0 {
            tapFormat = hwFormat
        } else if let fallback = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) {
            // HFP route in flux reported an invalid format; use a safe 16k mono
            // PCM format so installTap doesn't trap. SFSpeech accepts this.
            tapFormat = fallback
        } else {
            finish(continuation: continuation, error: SmartEarsError.other("No valid input format available."))
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            finish(continuation: continuation, error: SmartEarsError.other("Audio engine failed to start: \(error.localizedDescription)"))
            return
        }

        // Endpoint watchdog: stop the utterance on trailing silence or the cap.
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s poll
                guard let self, await self.isRunning else { return }
                let now = Date()
                let last = await self.lastUpdate
                if now.timeIntervalSince(last) >= silenceCap || now.timeIntervalSince(startedAt) >= hardCap {
                    await self.finish(continuation: continuation, error: nil)
                    return
                }
            }
        }
    }

    /// Actor-isolated handler for SFSpeechRecognizer callbacks. Running on the
    /// actor executor serializes all continuation access (the continuation is not
    /// thread-safe) and keeps `lastUpdate`/teardown state race-free.
    private func handleRecognition(
        payload: Transcription?,
        errorMessage: String?,
        continuation: AsyncThrowingStream<Transcription, Error>.Continuation
    ) {
        guard sessionActive else { return }
        if let payload {
            lastUpdate = Date()
            continuation.yield(payload)
            if payload.isFinal {
                finish(continuation: continuation, error: nil)
            }
        }
        if let errorMessage {
            finish(continuation: continuation, error: SmartEarsError.other("Recognition error: \(errorMessage)"))
        }
    }

    /// Finishes the stream and tears down exactly once, regardless of which path
    /// (final result, error, silence, or cap) triggered completion.
    private func finish(
        continuation: AsyncThrowingStream<Transcription, Error>.Continuation,
        error: Error?
    ) {
        guard sessionActive else { return }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        teardown()
    }

    private var isRunning: Bool { audioEngine.isRunning }

    /// Tears down the engine/tap/request for the current utterance. Idempotent:
    /// safe to call before starting a new utterance and on every completion path.
    private func teardown() {
        sessionActive = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        // Leave the audio session active so TTS can use it immediately; the
        // session manager owns activation/deactivation policy.
    }
}

// MARK: - Stub implementation

/// Deterministic stub for previews, unit tests, and running with no microphone
/// (e.g. the iOS Simulator, where live recognition is flaky). Emits a couple of
/// partials then a final canned transcription.
public struct StubSpeechRecognitionService: SpeechRecognizing {

    /// The final text the stub "hears". Override to script tests.
    public let scriptedText: String
    /// Artificial inter-partial delay so UI state transitions are observable.
    public let stepDelay: Duration

    public init(scriptedText: String = "what's the weather", stepDelay: Duration = .milliseconds(200)) {
        self.scriptedText = scriptedText
        self.stepDelay = stepDelay
    }

    public func transcribe() -> AsyncThrowingStream<Transcription, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let words = scriptedText.split(separator: " ").map(String.init)
                var building = ""
                for word in words {
                    building += building.isEmpty ? word : " \(word)"
                    continuation.yield(Transcription(text: building, isFinal: false, confidence: 0.9))
                    try? await Task.sleep(for: stepDelay)
                }
                continuation.yield(Transcription(text: scriptedText, isFinal: true, confidence: 0.95))
                continuation.finish()
            }
        }
    }
}
