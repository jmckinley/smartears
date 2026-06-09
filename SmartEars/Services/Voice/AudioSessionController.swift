//
//  AudioSessionController.swift
//  SmartEars — Voice layer
//
//  Single owner of the shared AVAudioSession for the voice loop. Splits the
//  session into two explicit PHASES so STT gets measurement-quality capture and
//  TTS gets A2DP-friendly wideband playback (instead of everything being pinned
//  to .measurement and routed through narrowband HFP). Also the ONLY place that
//  observes interruptions (phone call / Siri / alarm) and mediaServicesWereReset
//  — without these the engine stays dead after an interruption and the voice
//  loop wedges until app relaunch.
//

import Foundation
import AVFoundation

/// What the controller wants the live capture stream to do in response to a
/// session event. Delivered on the MainActor.
public enum AudioSessionEvent: Sendable {
    /// An interruption began (phone call, Siri, alarm). The active capture
    /// stream must end now; the engine is unusable until reactivation.
    case interruptionBegan
    /// Interruption ended and the system says we may resume, OR media services
    /// were reset. The session has been (re)configured for capture; a fresh
    /// utterance may be started by the consumer.
    case shouldRebuild
}

/// Owns AVAudioSession config + interruption/media-reset recovery for the voice
/// loop. MainActor-isolated: it mutates UI-adjacent voice state indirectly via
/// its event stream, and AVAudioSession config from a single actor avoids races.
@MainActor
public final class AudioSessionController {

    public static let shared = AudioSessionController()

    private let session = AVAudioSession.sharedInstance()
    private var observersInstalled = false

    /// Multicast of session events to interested consumers (the recognizer and
    /// RootView). AsyncStream continuations are stored and fed on the MainActor.
    private var continuations: [UUID: AsyncStream<AudioSessionEvent>.Continuation] = [:]

    private init() {}

    /// Subscribe to session events. Call once from the recognizer (to fail-fast
    /// its stream) and once from RootView (to restart the turn on rebuild).
    public func events() -> AsyncStream<AudioSessionEvent> {
        installObserversIfNeeded()
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    private func emit(_ event: AudioSessionEvent) {
        for c in continuations.values { c.yield(event) }
    }

    // MARK: Phase configuration

    /// CAPTURE phase: measurement-quality record. NOTE we deliberately DROP
    /// .defaultToSpeaker (contradicts a headset route) and .allowBluetoothA2DP
    /// (A2DP is output-only, moot while recording). HFP is the only BT input
    /// route, so .allowBluetoothHFP stays. No .duckOthers here either — ducking
    /// is applied only transiently and removed on idle so music un-ducks.
    public func configureForCapture() throws {
        installObserversIfNeeded()
        // .voiceChat mode reliably brings up the AirPods HFP mic for two-way voice
        // (and enables hardware echo cancellation, useful for barge-in). .measurement
        // disables processing and was slow/unreliable to establish the BT input.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .duckOthers]
        )
        try session.setActive(true)
    }

    /// PLAYBACK phase for TTS: spokenAudio mode keeps a wideband A2DP route to
    /// AirPods (instead of narrowband HFP) and reads naturally. We keep the
    /// category .playAndRecord so we don't tear down/rebuild the route mid-turn,
    /// but switch mode to .spokenAudio and allow A2DP for output.
    public func configureForPlayback() throws {
        installObserversIfNeeded()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        )
        try session.setActive(true)
    }

    /// ACTIVATION-HOLD phase: a playback session that genuinely CLAIMS the
    /// now-playing slot so SmartEars becomes the active media app and AirPod
    /// transport taps route to our MPRemoteCommandCenter handlers.
    ///
    /// We do NOT use .mixWithOthers: a subordinate/mixing audio source never
    /// becomes the Now Playing app, so taps would keep going to the user's music
    /// app instead of us. Claiming the slot is the documented tradeoff — while
    /// SmartEars is armed (foreground + AirPods) it owns media control, so opening
    /// the app pauses other audio; leaving the app releases it back (disarm /
    /// releaseActivationHold). .allowBluetoothA2DP keeps the wideband route.
    public func configureForActivationHold() throws {
        installObserversIfNeeded()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    /// Relinquish the activation hold, handing audio focus back to the user's
    /// music. Best-effort; a deactivation race is harmless. Callers MUST NOT
    /// invoke this while a capture/playback turn is live.
    public func releaseActivationHold() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Harmless deactivation race while the engine spins down.
        }
    }

    /// IDLE: deactivate so the user's music un-ducks, notifying other apps so
    /// they can resume at full volume. Best-effort; failures are non-fatal.
    public func deactivate() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // A deactivation race (engine still spinning down) is harmless here.
        }
    }

    // MARK: Interruption + media-reset recovery

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            // The notification's userInfo is plain values (Sendable); capture
            // them before hopping to the MainActor-isolated handler.
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }
        nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            // The OS has yanked the session; the engine is dead. End the
            // in-flight capture stream so the for-await loop exits cleanly.
            emit(.interruptionBegan)
        case .ended:
            guard shouldResume else { return }
            do {
                try configureForCapture()
                emit(.shouldRebuild)
            } catch {
                // Couldn't reactivate (rare); next user tap reconfigures.
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        // mediaServices reset destroys ALL audio objects. Rebuild the session
        // from scratch and signal consumers to recreate their engine/request.
        do {
            try configureForCapture()
            emit(.shouldRebuild)
        } catch {
            // Next user-initiated turn reconfigures.
        }
    }
}
