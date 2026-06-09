import SwiftUI

// MARK: - RootView (audio-first home screen)
//
// Voice is the primary surface, so this screen is intentionally minimal,
// glanceable, dark, and accessible. It centers on a big tap-to-talk / listening
// "orb" that reflects the `VoiceSessionState` from `AppEnvironment` (the app's
// single ObservableObject wiring VoiceSessionManager / ConversationManager /
// AlertMonitor responsibilities). Below the orb: the live transcript, the last
// assistant response, and an alerts banner.
//
// The tap target simulates a full voice turn end-to-end (parse -> route -> speak)
// so the pipeline is exercisable in the simulator without audio hardware or a
// wake word.

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var isProcessing = false
    @State private var showOnboarding = false
    /// The in-flight voice-turn Task, held so an .interrupt (AirPod double-tap)
    /// can cancel it — preventing a late completion from stomping the idle state.
    @State private var turnTask: Task<Void, Never>? = nil
    /// Bounds the `awaitingFollowUp` state so it can't hang: if no follow-up
    /// arrives within the window, settle back to `.idle`. (Music is already
    /// un-ducked on entry to the state.)
    @State private var followUpTimeout: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                SETheme.Colors.background.ignoresSafeArea()

                VStack(spacing: SETheme.Spacing.large) {
                    if !env.alerts.isEmpty {
                        alertsBanner
                    }

                    Spacer(minLength: 0)

                    statusLabel

                    ListeningOrb(state: env.voiceState, isBusy: isProcessing) {
                        startVoiceTurn()
                    }
                    .frame(height: 220)

                    AudioWaveformView(state: env.voiceState)
                        .frame(height: 60)
                        .opacity(env.voiceState == .idle ? 0.35 : 1)
                        .accessibilityHidden(true)

                    transcriptAndResponse

                    Spacer(minLength: 0)
                }
                .padding(SETheme.Spacing.large)
            }
            .navigationTitle("SmartEars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .preferredColorScheme(.dark)
            .onAppear {
                if !env.hasCompletedOnboarding { showOnboarding = true }
                // Claim the now-playing slot on first foreground so an idle AirPod
                // single-tap is caught immediately (NO wake word).
                env.refreshActivationArming(foreground: true)
            }
            .task {
                // Consume the AirPod activation stream for the view's lifetime.
                // single-tap (.activate) -> start a turn the same way the orb does;
                // double-tap (.interrupt) -> barge-in: stop TTS + cancel the turn.
                for await event in env.activation.events() {
                    switch event {
                    case .activate:
                        startVoiceTurn()                    // immediate: earcon+mic, NO wake word
                    case .interrupt:
                        turnTask?.cancel()
                        followUpTimeout?.cancel()
                        await env.speechSynthesizer.stop()
                        env.voiceState = .idle
                        env.liveTranscript = ""
                        isProcessing = false
                        // Re-claims the slot (un-ducks music, keeps single-tap live).
                        env.activation.endTurn()
                    }
                }
            }
            .task {
                // Carry-forward fix: consume the session's `shouldRebuild` event so
                // an interruption (call/Siri/alarm) or media-services reset that the
                // session recovered from re-arms the slot. Without this, recovery
                // left the slot un-claimed and taps stopped reaching SmartEars.
                for await sessionEvent in AudioSessionController.shared.events() {
                    if case .shouldRebuild = sessionEvent {
                        env.refreshActivationArming(foreground: scenePhase == .active)
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                env.refreshActivationArming(foreground: phase == .active)
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView()
                    .environmentObject(env)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                AlertsView().environmentObject(env)
            } label: {
                Image(systemName: env.alerts.isEmpty ? "bell" : "bell.badge.fill")
                    .foregroundStyle(SETheme.Colors.accent)
            }
            .accessibilityLabel("Alerts")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: SETheme.Spacing.medium) {
                if env.isUsingMockServices {
                    Text("MOCK")
                        .font(SETheme.Typography.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(SETheme.Colors.warning.opacity(0.2))
                        .foregroundStyle(SETheme.Colors.warning)
                        .clipShape(Capsule())
                        .accessibilityLabel("Running on mock services")
                }
                NavigationLink {
                    ConversationView().environmentObject(env)
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                NavigationLink {
                    SettingsView().environmentObject(env)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .foregroundStyle(SETheme.Colors.accent)
        }
    }

    // MARK: Status

    private var statusLabel: some View {
        Text(statusText)
            .font(SETheme.Typography.title)
            .foregroundStyle(SETheme.Colors.tint(for: env.voiceState))
            .contentTransition(.opacity)
            .animation(.easeInOut, value: env.voiceState)
            .accessibilityLabel("Assistant status: \(statusText)")
    }

    private var statusText: String {
        switch env.voiceState {
        case .idle: return "Tap to talk"
        case .waking: return "Waking…"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        case .awaitingFollowUp: return "Go on…"
        }
    }

    // MARK: Transcript + response

    private var transcriptAndResponse: some View {
        VStack(spacing: SETheme.Spacing.medium) {
            if !env.liveTranscript.isEmpty {
                Text("\u{201C}\(env.liveTranscript)\u{201D}")
                    .font(SETheme.Typography.headline)
                    .foregroundStyle(SETheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                    .accessibilityLabel("You said: \(env.liveTranscript)")
            }

            if let last = env.lastResponse {
                VStack(alignment: .leading, spacing: SETheme.Spacing.small) {
                    if let card = last.displayCard {
                        Label(card.title, systemImage: cardSymbol(for: card.kind))
                            .font(SETheme.Typography.caption)
                            .foregroundStyle(SETheme.Colors.textSecondary)
                    }
                    Text(last.spokenText)
                        .font(SETheme.Typography.body)
                        .foregroundStyle(SETheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let pending = last.pendingConfirmation {
                        Text(pending.readbackText)
                            .font(SETheme.Typography.caption)
                            .foregroundStyle(SETheme.Colors.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .seCard()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel("SmartEars said: \(last.spokenText)")
            }
        }
        .animation(.easeInOut, value: env.liveTranscript)
        .animation(.easeInOut, value: env.lastResponse?.id)
    }

    private func cardSymbol(for kind: DisplayCard.Kind) -> String {
        switch kind {
        case .conversation: return "bubble.left.and.bubble.right.fill"
        case .weather: return "cloud.sun.fill"
        case .stock: return "chart.line.uptrend.xyaxis"
        case .news: return "newspaper.fill"
        case .alert: return "exclamationmark.bubble.fill"
        case .email: return "envelope.fill"
        case .system: return "gearshape.fill"
        }
    }

    // MARK: Alerts banner

    private var alertsBanner: some View {
        NavigationLink {
            AlertsView().environmentObject(env)
        } label: {
            HStack(spacing: SETheme.Spacing.medium) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(SETheme.Colors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(topAlertTitle)
                        .font(SETheme.Typography.headline)
                        .foregroundStyle(SETheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(env.alerts.first?.spokenSummary ?? "")
                        .font(SETheme.Typography.subheadline)
                        .foregroundStyle(SETheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if env.alerts.count > 1 {
                    Text("\(env.alerts.count)")
                        .font(SETheme.Typography.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(SETheme.Colors.warning.opacity(0.2))
                        .foregroundStyle(SETheme.Colors.warning)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(SETheme.Colors.textSecondary)
            }
            .seCard()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(env.alerts.count) alerts. \(env.alerts.first?.spokenSummary ?? "")")
    }

    private var topAlertTitle: String {
        env.alerts.first.map { "New \($0.category.rawValue): \($0.title)" } ?? "Alerts"
    }

    // MARK: Voice turn (real capture)

    /// Runs one REAL voice turn end-to-end: chime -> live speech capture (STT) ->
    /// intent classification -> tool routing -> spoken response. Drives the same
    /// `VoiceSessionState` machine the UI reflects. Resilient throughout: a
    /// transcription failure (e.g. denied permission) settles back to idle with a
    /// spoken explanation, and an empty transcript falls back to "I didn't catch
    /// that." rather than crashing.
    private func startVoiceTurn() {
        guard !isProcessing else { return }
        isProcessing = true
        followUpTimeout?.cancel()
        // Tell the activation service a turn is live: its tap handlers now emit
        // .interrupt (double-tap) rather than a second .activate, and release()
        // won't tear the session out from under the in-flight turn.
        env.activation.turnDidStart()

        turnTask = Task { @MainActor in
            // listening: chime, then consume the live transcription stream.
            env.voiceState = .listening
            env.liveTranscript = ""
            await env.chime.playWakeChime()

            var finalText = ""
            do {
                for try await transcription in env.speechRecognizer.transcribe() {
                    if Task.isCancelled { return }   // barge-in: drop a stale turn
                    env.liveTranscript = transcription.text
                    if !transcription.text.isEmpty { finalText = transcription.text }
                }
            } catch {
                // A cancelled turn (AirPod double-tap barge-in) already reset state.
                if Task.isCancelled { return }
                // Surface the failure (commonly a permission error) and bail out.
                let detail = (error as? SmartEarsError)?.errorDescription
                    ?? error.localizedDescription
                let response = AssistantResponse(
                    spokenText: detail,
                    displayCard: DisplayCard(kind: .system, title: "Couldn't listen", body: detail)
                )
                env.lastResponse = response
                await env.speechSynthesizer.speak(response.spokenText)
                env.voiceState = .idle
                env.liveTranscript = ""
                env.activation.endTurn()  // re-claim slot + un-duck music
                isProcessing = false
                return
            }

            if Task.isCancelled { return }

            // Never crash on an empty transcript — speak a graceful fallback.
            let heard = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty else {
                let response = AssistantResponse(spokenText: "I didn't catch that.")
                env.lastResponse = response
                await env.speechSynthesizer.speak(response.spokenText)
                env.voiceState = .idle
                env.liveTranscript = ""
                env.activation.endTurn()  // re-claim slot + un-duck music
                isProcessing = false
                return
            }

            // thinking: classify the intent (LLM fallback) and route it. A watchdog
            // guarantees the turn can never hang here (e.g. a tool waiting on a slow
            // dependency like location) — without it a stuck turn leaves
            // isProcessing=true and the orb stops responding to the next tap.
            env.voiceState = .thinking
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, env.voiceState == .thinking else { return }
                turnTask?.cancel()
                env.liveTranscript = ""
                env.voiceState = .idle
                env.activation.endTurn()
                isProcessing = false
                await env.speechSynthesizer.speak("Sorry, that took too long. Please try again.")
            }
            let intent = (try? await env.llm.classifyIntent(transcript: heard))
                ?? .conversational(prompt: heard)
            let response = await env.toolRouter.route(intent)
            watchdog.cancel()

            if Task.isCancelled { return }

            // speaking: surface + speak the response.
            env.voiceState = .speaking
            env.history.insert(response, at: 0)
            env.lastResponse = response
            await env.speechSynthesizer.speak(response.spokenText)

            if Task.isCancelled { return }

            // settle: end the turn (re-claims the slot + un-ducks music) and, when
            // a follow-up is expected, show "Go on…" but bound it with a timeout so
            // the state can't hang and leave music ducked. Tapping the orb / an
            // AirPod single-tap continues the conversation.
            env.liveTranscript = ""
            env.activation.endTurn()
            isProcessing = false
            if response.followUpExpected {
                env.voiceState = .awaitingFollowUp
                followUpTimeout?.cancel()
                followUpTimeout = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(8))
                    if Task.isCancelled { return }
                    if env.voiceState == .awaitingFollowUp { env.voiceState = .idle }
                }
            } else {
                env.voiceState = .idle
            }
        }
    }
}

// MARK: - ListeningOrb
//
// The signature tap-to-talk control: a pulsing circular "orb" tinted by the
// current `VoiceSessionState`. Idle = calm/static; active states pulse. Tapping
// it triggers a voice turn. Fully accessible as a button.

private struct ListeningOrb: View {
    let state: VoiceSessionState
    let isBusy: Bool
    let action: () -> Void

    private var isActive: Bool { state != .idle }

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !isActive)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = isActive ? (sin(t * 3) + 1) / 2 : 0
                let tint = SETheme.Colors.tint(for: state)

                ZStack {
                    Circle()
                        .fill(tint.opacity(0.12))
                        .scaleEffect(1 + 0.18 * pulse)
                    Circle()
                        .fill(tint.opacity(0.22))
                        .scaleEffect(1 + 0.10 * pulse)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [tint, SETheme.Colors.accentSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 130, height: 130)
                        .shadow(color: tint.opacity(0.6), radius: isActive ? 24 : 8)
                    Image(systemName: isBusy ? "waveform" : "mic.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Tap to talk")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityValue: String {
        switch state {
        case .idle: return "Idle. Double tap to start listening."
        case .waking: return "Waking up."
        case .listening: return "Listening."
        case .thinking: return "Thinking."
        case .speaking: return "Speaking."
        case .awaitingFollowUp: return "Waiting for your follow-up."
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment())
}
