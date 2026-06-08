//
//  TextToSpeechService.swift
//  SmartEars — Voice layer
//
//  Text-to-speech is the PRIMARY output surface for SmartEars (an audio-first
//  assistant). This wraps `AVSpeechSynthesizer` to speak assistant responses and
//  supports "barge-in": the user (or the session manager) can stop in-progress
//  speech immediately — e.g. when a new wake word arrives or the user says
//  "stop" — so the assistant feels interruptible like Meta/Gemini voice modes.
//
//  Notes:
//   * `AVSpeechSynthesizer` mixes with the app's audio session; the session
//     manager is responsible for the route/category (so TTS plays through the
//     AirPods). We duck/Stop politely.
//   * `speak(_:)` is `async` and returns when the utterance finishes (or is
//     stopped), making it easy to sequence in the state machine.
//

import Foundation
import AVFoundation

// MARK: - Configuration

/// Voice/rate/pitch parameters for spoken output.
public struct SpeechVoiceConfig: Sendable {
    public var languageCode: String
    public var rate: Float          // 0.0...1.0 (AVSpeechUtterance scale)
    public var pitchMultiplier: Float
    public var volume: Float

    public init(
        languageCode: String = "en-US",
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        pitchMultiplier: Float = 1.0,
        volume: Float = 1.0
    ) {
        self.languageCode = languageCode
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        self.volume = volume
    }

    public static let `default` = SpeechVoiceConfig()
}

// MARK: - Live implementation

/// Live TTS using `AVSpeechSynthesizer`, conforming to `SpeechSynthesizing`
/// (Models.swift). Supports barge-in via `stop()` which halts immediately.
///
/// The synthesizer and its delegate live on the main actor because
/// `AVSpeechSynthesizer` posts delegate callbacks on the main queue and is not
/// `Sendable`; the public API is async so callers can `await` completion.
public final class LiveTextToSpeechService: NSObject, SpeechSynthesizing, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let config: SpeechVoiceConfig

    /// Resumes the `speak` continuation when the current utterance finishes,
    /// is cancelled (barge-in), or fails to start.
    private var completion: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    public init(config: SpeechVoiceConfig = .default) {
        self.config = config
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` and returns when the utterance completes or is stopped.
    public func speak(_ text: String) async {
        // If something is already speaking, barge-in over it first.
        await stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            self.completion = continuation
            lock.unlock()

            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = AVSpeechSynthesisVoice(language: config.languageCode)
            utterance.rate = config.rate
            utterance.pitchMultiplier = config.pitchMultiplier
            utterance.volume = config.volume
            synthesizer.speak(utterance)
        }
    }

    /// Barge-in: stops any in-progress speech immediately and resolves the
    /// pending `speak` call. Safe to call when nothing is speaking.
    public func stop() async {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            // `.immediate` halts at the current word boundary right away.
            synthesizer.stopSpeaking(at: .immediate)
        }
        resumeCompletion()
    }

    /// Resolve and clear the pending continuation exactly once.
    private func resumeCompletion() {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?.resume()
    }
}

// MARK: AVSpeechSynthesizerDelegate

extension LiveTextToSpeechService: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resumeCompletion()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resumeCompletion()
    }
}

// MARK: - Stub implementation

/// Non-audible stub for previews/tests. Simulates speaking duration (so state
/// machines that gate on speech completion behave realistically) and honors
/// barge-in via `stop()`.
public actor StubTextToSpeechService: SpeechSynthesizing {

    /// Approximate words-per-minute used to fake an utterance's duration.
    private let wordsPerMinute: Double
    private var speakTask: Task<Void, Never>?

    /// Captures everything "spoken" for test assertions.
    public private(set) var spokenLog: [String] = []

    public init(wordsPerMinute: Double = 170) {
        self.wordsPerMinute = wordsPerMinute
    }

    public func speak(_ text: String) async {
        await stop()
        spokenLog.append(text)
        let wordCount = max(1, text.split(separator: " ").count)
        let seconds = Double(wordCount) / (wordsPerMinute / 60.0)
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        speakTask = task
        await task.value
        speakTask = nil
    }

    public func stop() async {
        speakTask?.cancel()
        speakTask = nil
    }
}
