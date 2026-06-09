//
//  NowPlayingActivationService.swift
//  SmartEars — Voice layer
//
//  Native AirPod activation engine. To receive AirPod hardware taps, SmartEars
//  must be the active "now playing" app. We claim that slot (an AVAudioSession
//  playback hold + a populated MPNowPlayingInfoCenter + a near-silent looping
//  player) while ARMED, register MPRemoteCommandCenter transport handlers, and
//  translate them into a clean `ActivationEvent` stream:
//
//    * single physical press -> play/pause family -> .activate
//    * double physical press -> nextTrack          -> .interrupt (barge-in)
//
//  Disambiguation is by COMMAND IDENTITY (which MPRemoteCommand fired) plus a
//  250 ms coalescing debounce — never by counting taps ourselves. We release the
//  slot back to the user's music when disarmed.
//
//  HONEST TRADEOFF: while armed (foreground + AirPods + tap-control on) SmartEars
//  owns the now-playing slot, so an AirPod tap talks to SmartEars instead of the
//  user's music. We minimize the cost: we arm ONLY in the foreground, the
//  activation-hold session uses .mixWithOthers (NOT .duckOthers) so arming alone
//  never lowers the music, and a Settings toggle disables the takeover entirely.
//
//  AVAudioSession is touched EXCLUSIVELY through AudioSessionController (the sole
//  session owner) — never directly. MainActor-isolated end to end so the
//  AsyncStream continuation, debounce state, and slot ownership share one actor
//  with no lock and no continuation race.
//

import Foundation
import AVFoundation
import MediaPlayer

/// A discrete activation intent derived from an AirPod hardware tap.
public enum ActivationEvent: Sendable, Equatable {
    /// Single-tap: start a voice turn immediately (earcon + mic + recognition).
    /// NEVER requires a subsequent wake word.
    case activate
    /// Double-tap: barge-in. Stop in-progress TTS and cancel the current turn.
    case interrupt
}

/// Native AirPod activation engine. See file header for the full lifecycle.
///
/// MainActor-isolated: the AsyncStream continuation, debounce state, and slot
/// ownership are all touched only on the main actor, so there is no lock and no
/// continuation race. Single-subscriber by design.
@MainActor
public final class NowPlayingActivationService: NSObject {

    // MARK: Single-subscriber event stream

    private var continuation: AsyncStream<ActivationEvent>.Continuation?

    /// The activation event stream. Single-subscriber: a second call finishes the
    /// previous stream so there is never a double-emit across two continuations.
    public func events() -> AsyncStream<ActivationEvent> {
        continuation?.finish()
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuation = nil }
            }
        }
    }

    // MARK: State

    private let session: AudioSessionController
    private var isArmed = false
    /// Set by the turn loop so handlers know whether a tap should activate or
    /// interrupt, and so release never tears down a live turn.
    public private(set) var isTurnActive = false

    /// Near-silent looping player that reinforces ownership of the now-playing
    /// slot while armed. nil when disarmed.
    private var holdPlayer: AVAudioPlayer?

    /// Block-target tokens for every MPRemoteCommand we register, so we remove the
    /// exact handlers on disarm and never leak across arm/disarm cycles.
    private var commandTokens: [(command: MPRemoteCommand, token: Any)] = []

    /// Debounce: last emit time, to coalesce the duplicate callbacks iOS fires for
    /// one physical press and enforce a global minimum between any two events.
    private var lastEmitAt: Date = .distantPast
    private let debounceWindow: TimeInterval = 0.25

    /// True once we have installed the route-change observer (idempotent).
    private var routeObserverInstalled = false

    public init(session: AudioSessionController = .shared) {
        self.session = session
        super.init()
    }

    // MARK: Turn coordination (called by RootView)

    public func turnDidStart() {
        isTurnActive = true
        // Hand the audio hardware to the capture/playback path for the turn. Leaving
        // the silent hold player running while the engine starts capture on a live
        // Bluetooth route can destabilize the input format. endTurn() restarts it.
        stopHoldPlayer()
    }
    public func turnDidEnd() { isTurnActive = false }

    /// Called at every turn terminal path (completion, error, empty, interrupt,
    /// follow-up). Ends the turn and EITHER re-claims the now-playing hold — when
    /// we should still be armed, which un-ducks the user's music via the
    /// `.mixWithOthers` hold session AND keeps the slot + command handlers live so
    /// the NEXT idle single-tap still activates — OR fully releases the session.
    ///
    /// Fixes the "single-tap works only once per foregrounding" bug: previously
    /// the turn loop called `deactivate()` directly, tearing down the slot while
    /// `isArmed` stayed true, so `arm()` (guarded by `!isArmed`) never re-claimed it.
    public func endTurn() {
        isTurnActive = false
        let shouldArm = lastForeground && lastTapControlEnabled && isHeadphoneRoute
        if shouldArm {
            isArmed = true
            try? session.configureForActivationHold()  // .mixWithOthers → un-ducks music
            startHoldPlayer()                           // ensure the hold player is running
            publishNowPlaying()                         // refresh playbackState = .playing
            registerCommands()                          // idempotent (self-unregisters first)
        } else {
            isArmed = false
            unregisterCommands()
            stopHoldPlayer()
            clearNowPlaying()
            session.deactivate()
        }
    }

    // MARK: Arming

    /// Claim the now-playing slot so a single-tap from idle activates SmartEars.
    /// Idempotent. Coordinates the session through AudioSessionController only.
    public func arm() {
        guard !isArmed else { return }
        isArmed = true
        try? session.configureForActivationHold()
        startHoldPlayer()
        publishNowPlaying()
        registerCommands()
    }

    /// Release the slot back to the user's music. Idempotent. Will NOT deactivate
    /// the shared session if a voice turn is in flight (the turn owns it then).
    public func disarm() {
        guard isArmed else { return }
        isArmed = false
        unregisterCommands()
        stopHoldPlayer()
        clearNowPlaying()
        if !isTurnActive { session.releaseActivationHold() }
    }

    /// Re-evaluate arming from the current foreground + route + setting inputs.
    /// Called by the owner on scene-phase change, route change, and setting flips.
    public func updateArming(foreground: Bool, tapControlEnabled: Bool) {
        installRouteObserverIfNeeded()
        self.lastForeground = foreground
        self.lastTapControlEnabled = tapControlEnabled
        // NOTE: we do NOT gate on isHeadphoneRoute. Before SmartEars activates any
        // audio session, AVAudioSession.currentRoute reports the built-in speaker
        // even when AirPods are connected — so gating on it meant arm() never ran
        // and the now-playing slot was never claimed ("Not Playing"). Claiming the
        // hold session is itself what engages the AirPods route. Tap control is an
        // explicit opt-out (default on); that's the user's lever, not route guessing.
        let shouldArm = foreground && tapControlEnabled
        if shouldArm { arm() } else { disarm() }
    }

    /// Cached inputs so the route-change observer can re-evaluate arming using the
    /// most recent foreground + setting values without a new caller call.
    private var lastForeground = false
    private var lastTapControlEnabled = true

    private var isHeadphoneRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .bluetoothA2DP || output.portType == .bluetoothLE ||
            output.portType == .headphones || output.portType == .bluetoothHFP
        }
    }

    /// Live snapshot of the activation/now-playing claim state, surfaced on-screen
    /// so we can see exactly which step of the slot claim is (or isn't) happening.
    public func debugSnapshot() -> String {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue.replacingOccurrences(of: "AVAudioSessionPort", with: "") }
            .joined(separator: ",")
        let playing = holdPlayer?.isPlaying ?? false
        let npInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
        let state = MPNowPlayingInfoCenter.default().playbackState == .playing ? "playing" : "other"
        return "tap:\(lastTapControlEnabled ? "on" : "off") armed:\(isArmed) hold:\(playing) npInfo:\(npInfo) npState:\(state) out:[\(out.isEmpty ? "none" : out)]"
    }

    // MARK: Route observer (re-arm on AirPods connect/disconnect)

    /// Single owner of the route-change observer for arming. (AudioSessionController
    /// observes interruptions only; AirPodInputService observes route changes for
    /// auto-pause — this observer is scoped strictly to re-evaluating arming.)
    private func installRouteObserverIfNeeded() {
        guard !routeObserverInstalled else { return }
        routeObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let shouldArm = self.lastForeground
                    && self.lastTapControlEnabled
                    && self.isHeadphoneRoute
                if shouldArm { self.arm() } else { self.disarm() }
            }
        }
    }

    // MARK: Now-playing slot

    private func publishNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "SmartEars"
        info[MPMediaItemPropertyArtist] = "Tap to talk"
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = .playing
    }

    private func clearNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    // MARK: Near-silent hold player

    private func startHoldPlayer() {
        guard holdPlayer == nil else { return }
        // Generated in code (no bundled asset): looping silent PCM. Actually
        // *producing* audio is what makes iOS deliver AirPod transport taps to our
        // MPRemoteCommandCenter handlers, so the hold player must really play.
        guard let player = try? AVAudioPlayer(data: Self.silentWAVData) else { return }
        player.numberOfLoops = -1
        // Full volume is still SILENT (the buffer is all-zero samples), but a
        // volume-0 player can be treated by iOS as "not producing audio" and fail
        // to claim the now-playing slot — which is what we need to receive taps.
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
        holdPlayer = player
    }

    private func stopHoldPlayer() {
        holdPlayer?.stop()
        holdPlayer = nil
    }

    /// ~0.5 s of mono 16-bit PCM silence in a WAV container, built once in code so
    /// the now-playing hold needs no bundled `silence.caf` resource.
    private static let silentWAVData: Data = makeSilentWAV(seconds: 0.5, sampleRate: 8_000)

    private static func makeSilentWAV(seconds: Double, sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let frameCount = Int(Double(sampleRate) * seconds)
        let dataSize = frameCount * channels * (bitsPerSample / 8)
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataSize))
        d.append(Data(count: dataSize))  // zeros = silence
        return d
    }

    // MARK: Remote command handlers

    private func registerCommands() {
        // Defensive: clear any previously registered targets first so re-arming
        // never stacks duplicate handlers.
        unregisterCommands()

        let center = MPRemoteCommandCenter.shared()

        // Enable ONLY the commands AirPod taps map to; a single physical press
        // surfaces as togglePlayPause/play/pause, a double press as nextTrack.
        for command in [center.togglePlayPauseCommand,
                        center.playCommand,
                        center.pauseCommand] {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                self?.handleSingleTap() ?? .commandFailed
            }
            commandTokens.append((command, token))
        }

        center.nextTrackCommand.isEnabled = true
        let nextToken = center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleDoubleTap() ?? .commandFailed
        }
        commandTokens.append((center.nextTrackCommand, nextToken))

        // Explicitly disable every other command so we don't fight other media
        // apps' controls or surface stray transport affordances.
        for disabled in [center.previousTrackCommand,
                         center.seekForwardCommand,
                         center.seekBackwardCommand,
                         center.skipForwardCommand,
                         center.skipBackwardCommand,
                         center.changePlaybackPositionCommand] {
            disabled.isEnabled = false
        }
    }

    private func unregisterCommands() {
        for entry in commandTokens {
            entry.command.removeTarget(entry.token)
            entry.command.isEnabled = false
        }
        commandTokens.removeAll()
    }

    /// Single physical press -> play/pause family -> .activate.
    private func handleSingleTap() -> MPRemoteCommandHandlerStatus {
        // While a turn is active, a play/pause press is a no-op (only double-tap
        // interrupts). From idle it activates immediately — NO wake word.
        guard !isTurnActive else { return .success }
        emit(.activate)
        return .success
    }

    /// Double press -> nextTrack -> .interrupt (barge-in). No-op from idle.
    private func handleDoubleTap() -> MPRemoteCommandHandlerStatus {
        guard isTurnActive else { return .success }
        emit(.interrupt)
        return .success
    }

    /// Coalescing gate: drops duplicate/storm callbacks inside the debounce
    /// window so one physical press yields at most one event, and enforces a
    /// global 250 ms minimum between ANY two emitted events.
    private func emit(_ event: ActivationEvent) {
        let now = Date()
        guard now.timeIntervalSince(lastEmitAt) >= debounceWindow else { return }
        lastEmitAt = now
        continuation?.yield(event)
    }
}
