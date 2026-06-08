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
    @State private var isProcessing = false
    @State private var showOnboarding = false

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
                        simulateVoiceTurn()
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

    // MARK: Voice turn (simulated)

    /// Runs one mock voice turn end-to-end so the pipeline is exercisable in the
    /// simulator without audio hardware. A real build drives this from the
    /// VoiceSessionCoordinator (wake -> STT -> intent -> route -> TTS).
    private func simulateVoiceTurn() {
        guard !isProcessing else { return }
        isProcessing = true
        let utterance = "what's the weather"

        Task { @MainActor in
            // listening
            env.voiceState = .listening
            await env.chime.playWakeChime()
            env.liveTranscript = utterance

            // thinking
            env.voiceState = .thinking
            let intent = (try? await env.llm.classifyIntent(transcript: utterance))
                ?? .conversational(prompt: utterance)
            let response = await env.toolRouter.route(intent)

            // speaking
            env.voiceState = .speaking
            env.history.insert(response, at: 0)
            env.lastResponse = response
            await env.speechSynthesizer.speak(response.spokenText)

            // settle
            env.voiceState = response.followUpExpected ? .awaitingFollowUp : .idle
            env.liveTranscript = ""
            isProcessing = false
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
