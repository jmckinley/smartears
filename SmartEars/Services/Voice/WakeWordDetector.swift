//
//  WakeWordDetector.swift
//  SmartEars — Voice layer
//
//  Configurable trigger-phrase ("wake word") detection layered over a continuous
//  speech-recognition stream. When the running transcription contains the
//  configured phrase (case-insensitive), a "detected" event is published.
//
//  HONEST iOS LIMITATION:
//  ----------------------
//  True low-power, always-on keyword spotting — the way first-party "Hey Siri"
//  runs on a dedicated, low-power audio coprocessor — is NOT available to
//  third-party apps. Apple exposes no public always-on KWS API. A genuinely
//  efficient custom wake word would require bundling a dedicated keyword-spotting
//  model (e.g. a small CoreML / TFLite KWS network) and running it over raw audio
//  frames yourself, accepting the battery cost of keeping the mic open.
//
//  This implementation is the PRAGMATIC Speech-framework approach: we run
//  `SFSpeechRecognizer` continuously and string-match the configured phrase
//  against the live transcript. It is simple and works offline (on-device
//  recognition), but it keeps a recognition session and the mic active, so it is
//  intended for foreground / actively-listening sessions rather than indefinite
//  background standby. The `WakeWordEngine` protocol (Models.swift) is the seam
//  where a real bundled KWS model could be substituted without touching callers.
//

import Foundation

/// Live wake-word engine using continuous speech recognition + phrase matching.
///
/// Conforms to `WakeWordEngine` (Models.swift): it emits a `Date` on each
/// detection via `wakeEvents()` and lets the phrase be reconfigured at runtime.
///
/// Detection runs recognition utterances back-to-back. On each partial/final
/// transcript we normalize and substring-match the wake phrase; a debounce
/// window prevents repeated firing from the same lingering transcript.
public actor WakeWordDetector: WakeWordEngine {

    private let recognizer: SpeechRecognizing
    private var phrase: String
    /// Minimum gap between two consecutive detections (debounce).
    private let rearmInterval: TimeInterval
    private var lastDetectedAt: Date = .distantPast

    /// Continuation for the published detection stream.
    private var continuation: AsyncStream<Date>.Continuation?
    /// The long-running listen loop; cancelled on stop.
    private var listenTask: Task<Void, Never>?

    /// - Parameters:
    ///   - recognizer: any `SpeechRecognizing` (live or stub) producing transcripts.
    ///   - triggerConfig: source of the initial wake phrase.
    ///   - rearmInterval: debounce so one utterance doesn't fire repeatedly.
    public init(
        recognizer: SpeechRecognizing,
        triggerPhrase: String,
        rearmInterval: TimeInterval = 2.0
    ) {
        self.recognizer = recognizer
        self.phrase = WakeWordDetector.normalize(triggerPhrase)
        self.rearmInterval = rearmInterval
    }

    // MARK: WakeWordEngine

    /// Emits a timestamp every time the wake phrase is detected. Starting to
    /// iterate this stream kicks off the continuous listen loop; dropping it
    /// (termination) stops listening.
    nonisolated public func wakeEvents() -> AsyncStream<Date> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
        }
    }

    /// Updates the phrase to listen for. Safe to call while listening.
    nonisolated public func setWakePhrase(_ phrase: String) {
        Task { await self.updatePhrase(phrase) }
    }

    // MARK: Internals

    private func attach(_ continuation: AsyncStream<Date>.Continuation) {
        self.continuation = continuation
        startListening()
    }

    private func updatePhrase(_ newPhrase: String) {
        phrase = WakeWordDetector.normalize(newPhrase)
    }

    /// Runs recognition utterances back-to-back, matching the wake phrase on
    /// every transcript update. Restarts the recognizer after each utterance
    /// completes (silence/cap) so listening is effectively continuous.
    private func startListening() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let stream = self.recognizer.transcribe()
                    for try await transcription in stream {
                        if Task.isCancelled { return }
                        await self.evaluate(transcription)
                    }
                } catch {
                    // Recognition error (permission revoked, locale change, etc.).
                    // Brief backoff before re-arming so we don't hot-loop on failure.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if Task.isCancelled { return }
            }
        }
    }

    /// Checks a transcript for the wake phrase and publishes a detection.
    private func evaluate(_ transcription: Transcription) {
        let haystack = WakeWordDetector.normalize(transcription.text)
        guard !phrase.isEmpty, WakeWordDetector.containsPhrase(haystack, phrase: phrase) else { return }

        let now = Date()
        guard now.timeIntervalSince(lastDetectedAt) >= rearmInterval else { return }
        lastDetectedAt = now
        continuation?.yield(now)
    }

    private func stop() {
        listenTask?.cancel()
        listenTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Lowercase + collapse whitespace for forgiving, case-insensitive matching.
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Word-boundary phrase match: returns true only when the phrase's word
    /// tokens appear as a contiguous run of whole words in the haystack. This
    /// avoids substring false positives (e.g. "art" matching inside "smart").
    /// Both inputs are expected to be `normalize`d (lowercased, single-spaced).
    private static func containsPhrase(_ haystack: String, phrase: String) -> Bool {
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard !phraseTokens.isEmpty else { return false }

        let haystackTokens = haystack.split(separator: " ").map(String.init)
        guard haystackTokens.count >= phraseTokens.count else { return false }

        let lastStart = haystackTokens.count - phraseTokens.count
        for start in 0...lastStart {
            if Array(haystackTokens[start..<(start + phraseTokens.count)]) == phraseTokens {
                return true
            }
        }
        return false
    }
}
