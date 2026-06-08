//
//  AirPodInputService.swift
//  SmartEars — Voice layer
//
//  Handles AirPod-relevant input and maps a configurable control to an action.
//  SmartEars treats AirPods as the wearable, so we surface the realistic signals
//  iOS DOES expose about them.
//
//  HONEST AirPod-gesture reality (what Apple does / does NOT expose):
//  ------------------------------------------------------------------
//   * Raw stem-press / "squeeze" / force-sensor events are NOT delivered to
//     third-party apps. There is no API to read an AirPods Pro squeeze, a long
//     press, or the press-and-hold-to-switch-mode gesture directly.
//   * What we CAN observe, and what this service uses:
//       1. Transport intents via `MPRemoteCommandCenter` — when the user uses an
//          AirPod stem to play/pause/skip while our audio is the Now Playing
//          source, iOS routes those as play/pause/next/previous commands. We map
//          these to `AirPodGesture.singlePress` / `.doublePress` / `.triplePress`.
//       2. Route / port changes via `AVAudioSession.routeChangeNotification` —
//          tells us when AirPods become the output (bud inserted) or are removed
//          (old-device-unavailable -> `.earBudRemoved`, the canonical auto-pause
//          trigger).
//       3. (Head nod/shake via `CMHeadphoneMotionManager` exists on supported
//          AirPods but lives in the Gestures module; this service focuses on
//          transport + route signals and the configurable action mapping.)
//   * Therefore "AirPod gestures" here are RECONSTRUCTED from these allowed
//     signals, not read from a private stem-press API. Confidence is 1.0 for
//     these deterministic transport/route events.
//

import Foundation
import AVFoundation
import MediaPlayer

/// A user-configurable mapping from an AirPod control to a SmartEars action.
/// Because real stem gestures aren't exposed, the "gesture" is whichever
/// transport command the user triggers from the AirPod (play/pause -> single,
/// next -> double, previous -> triple), mapped to an app action.
public struct AirPodControlMapping: Sendable {
    /// Which observed gesture activates the assistant (e.g. a single press to
    /// "wake without saying the wake word").
    public var activationGesture: AirPodGesture
    /// Whether removing a bud should request a pause of the assistant/output.
    public var pauseOnRemoval: Bool

    public init(
        activationGesture: AirPodGesture = .singlePress,
        pauseOnRemoval: Bool = true
    ) {
        self.activationGesture = activationGesture
        self.pauseOnRemoval = pauseOnRemoval
    }

    public static let `default` = AirPodControlMapping()
}

/// Observes AirPod transport + route signals and emits `GestureEvent`s.
///
/// Conforms to `GestureService` (Models.swift). It also exposes a small
/// `isAirPodsConnected` snapshot and an `activationEvents()` convenience stream
/// that filters to the configured activation gesture, so the session manager can
/// "wake on press" without re-deriving the mapping.
public final class AirPodInputService: NSObject, GestureService, @unchecked Sendable {

    private var mapping: AirPodControlMapping
    private let commandCenter = MPRemoteCommandCenter.shared()

    private var continuation: AsyncStream<GestureEvent>.Continuation?
    private let lock = NSLock()

    public init(mapping: AirPodControlMapping = .default) {
        self.mapping = mapping
        super.init()
    }

    // MARK: GestureService

    /// Emits `GestureEvent`s reconstructed from transport commands and audio
    /// route changes. Starting to iterate installs the handlers; termination
    /// removes them.
    public func gestureEvents() -> AsyncStream<GestureEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            self.installHandlers()
            continuation.onTermination = { [weak self] _ in
                self?.removeHandlers()
            }
        }
    }

    /// Convenience: only the configured activation gesture (e.g. single press),
    /// for "wake on AirPod control" behavior in the session manager.
    public func activationEvents() -> AsyncStream<Date> {
        let mappingGesture = mapping.activationGesture
        let source = gestureEvents()
        return AsyncStream { continuation in
            let task = Task {
                for await event in source where event.gesture == mappingGesture {
                    continuation.yield(event.occurredAt)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Best-effort snapshot of whether AirPods/Bluetooth headphones are the
    /// current output route. (We cannot identify the exact model reliably.)
    public var isAirPodsConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { output in
            output.portType == .bluetoothA2DP ||
            output.portType == .bluetoothLE ||
            output.portType == .headphones
        }
    }

    // MARK: Transport handlers (MPRemoteCommandCenter)

    private func installHandlers() {
        // play/pause -> single press toggle
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget(self, action: #selector(handleTogglePlayPause))
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget(self, action: #selector(handleTogglePlayPause))
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget(self, action: #selector(handleTogglePlayPause))

        // next -> double press
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget(self, action: #selector(handleNext))

        // previous -> triple press
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget(self, action: #selector(handlePrevious))

        // route changes -> bud inserted / removed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    private func removeHandlers() {
        commandCenter.togglePlayPauseCommand.removeTarget(self)
        commandCenter.playCommand.removeTarget(self)
        commandCenter.pauseCommand.removeTarget(self)
        commandCenter.nextTrackCommand.removeTarget(self)
        commandCenter.previousTrackCommand.removeTarget(self)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)

        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    private func emit(_ gesture: AirPodGesture, confidence: Float = 1.0) {
        lock.lock()
        let cont = continuation
        lock.unlock()
        cont?.yield(GestureEvent(gesture: gesture, confidence: confidence))
    }

    @objc private func handleTogglePlayPause() -> MPRemoteCommandHandlerStatus {
        emit(.singlePress)
        return .success
    }

    @objc private func handleNext() -> MPRemoteCommandHandlerStatus {
        emit(.doublePress)
        return .success
    }

    @objc private func handlePrevious() -> MPRemoteCommandHandlerStatus {
        emit(.triplePress)
        return .success
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .newDeviceAvailable:
            // A bud/headset became available -> treat as inserted.
            if isAirPodsConnected { emit(.earBudInserted) }
        case .oldDeviceUnavailable:
            // The canonical "AirPod removed from ear / disconnected" signal —
            // this is what powers auto-pause on removal.
            emit(.earBudRemoved)
        default:
            break
        }
    }
}

// MARK: - Stub implementation

/// Scriptable stub emitting a fixed sequence of gesture events for previews and
/// tests — no MediaPlayer/AVAudioSession dependency required.
public final class StubAirPodInputService: GestureService, @unchecked Sendable {

    private let scripted: [GestureEvent]
    private let interval: Duration

    public init(scripted: [GestureEvent] = [GestureEvent(gesture: .singlePress)], interval: Duration = .milliseconds(300)) {
        self.scripted = scripted
        self.interval = interval
    }

    public func gestureEvents() -> AsyncStream<GestureEvent> {
        AsyncStream { continuation in
            let task = Task {
                for event in scripted {
                    try? await Task.sleep(for: interval)
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
