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
//       1. Route / port changes via `AVAudioSession.routeChangeNotification` —
//          tells us when AirPods become the output (bud inserted) or are removed
//          (old-device-unavailable -> `.earBudRemoved`, the canonical auto-pause
//          trigger). This is the ONLY real AirPod signal this service emits.
//       2. (Head nod/shake via `CMHeadphoneMotionManager` exists on supported
//          AirPods but lives in the Gestures module.)
//   * We deliberately do NOT map MPRemoteCommandCenter transport commands
//     (play/pause/next/prev) to "gestures": on real AirPods our app is never the
//     Now Playing source so they never fire for us, and claiming them would
//     hijack/pause the user's music. Stem-press wake is reserved by iOS to Siri.
//

import Foundation
import AVFoundation

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

    // MARK: Route handlers (AVAudioSession)

    private func installHandlers() {
        // iOS does NOT deliver raw AirPods stem-press / squeeze / force-sensor
        // events to third-party apps, and the press-and-hold-to-wake gesture is
        // reserved for Siri. We previously claimed MPRemoteCommandCenter
        // transport commands (play/pause/next/prev) as AirPod "gestures", but:
        //   * our app is never the Now Playing source, so on real AirPods those
        //     callbacks never fire for us, and
        //   * registering them would HIJACK / pause the user's actual music.
        // So we register NO transport handlers. The only honest, real signal we
        // can observe is the audio route change (bud inserted / removed).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    private func removeHandlers() {
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
