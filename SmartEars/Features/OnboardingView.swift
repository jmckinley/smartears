import SwiftUI
import AVFoundation
import Speech
import UserNotifications

// MARK: - OnboardingView
//
// A short, paged onboarding that (1) explains the AirPods-as-wearable concept,
// (2) requests the permissions the voice pipeline needs — microphone, speech
// recognition, and notifications — and (3) lets the user pick a trigger/wake
// word. On finish it commits the wake phrase to the WakeWordEngine and marks
// onboarding complete on `AppEnvironment`.
//
// Permission requests use the real system APIs (AVAudioSession / Speech /
// UNUserNotificationCenter). Make sure the matching Info.plist usage strings
// (NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription) are present
// or the request will crash on a device — they are configured in Info/Info.plist.

struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var wakePhrase = "Hey SmartEars"
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var notificationsGranted = false

    private let suggestions = ["Hey SmartEars", "Hey Ears", "Okay Ears", "Listen Up"]

    var body: some View {
        ZStack {
            SETheme.Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    conceptPage.tag(0)
                    permissionsPage.tag(1)
                    wakeWordPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                footer
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    // MARK: Page 1 — concept

    private var conceptPage: some View {
        OnboardingPage(
            symbol: "airpodspro",
            title: "Your AirPods, your assistant.",
            subtitle: "SmartEars treats your AirPods like smart glasses — without a camera or display."
        ) {
            VStack(alignment: .leading, spacing: SETheme.Spacing.medium) {
                FeatureRow(symbol: "waveform", text: "Ask out loud — weather, stocks, news, and more.")
                FeatureRow(symbol: "bell.badge", text: "Hear a chime and a spoken summary for important messages.")
                FeatureRow(symbol: "hand.tap", text: "Use AirPod gestures and a head nod or shake to confirm.")
                FeatureRow(symbol: "lock.shield", text: "Runs on private, on-device speech. No keys required to start.")
            }
            .padding(.top, SETheme.Spacing.large)
        }
    }

    // MARK: Page 2 — permissions

    private var permissionsPage: some View {
        OnboardingPage(
            symbol: "checkmark.shield",
            title: "A few permissions",
            subtitle: "SmartEars needs these to listen, transcribe, and alert you."
        ) {
            VStack(spacing: SETheme.Spacing.medium) {
                PermissionRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "Hear your voice for hands-free questions.",
                    granted: micGranted,
                    action: requestMic
                )
                PermissionRow(
                    symbol: "waveform.and.mic",
                    title: "Speech Recognition",
                    detail: "Turn your speech into text on-device.",
                    granted: speechGranted,
                    action: requestSpeech
                )
                PermissionRow(
                    symbol: "bell.fill",
                    title: "Notifications",
                    detail: "Surface important messages and emails as alerts.",
                    granted: notificationsGranted,
                    action: requestNotifications
                )
            }
            .padding(.top, SETheme.Spacing.large)
        }
    }

    // MARK: Page 3 — wake word

    private var wakeWordPage: some View {
        OnboardingPage(
            symbol: "waveform.badge.mic",
            title: "Pick a wake word",
            subtitle: "Say it to start a hands-free turn without tapping."
        ) {
            VStack(spacing: SETheme.Spacing.medium) {
                TextField("Wake phrase", text: $wakePhrase)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(SETheme.Typography.title)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(SETheme.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: SETheme.Radius.card, style: .continuous))

                FlexibleChips(items: suggestions, selection: wakePhrase) { phrase in
                    wakePhrase = phrase
                }

                Text("iOS limits fully-custom on-device keyword models; SmartEars matches your phrase with on-device speech recognition.")
                    .font(SETheme.Typography.caption)
                    .foregroundStyle(SETheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, SETheme.Spacing.large)
        }
    }

    // MARK: Footer (advance / finish)

    private var footer: some View {
        Button(action: advance) {
            Text(page == 2 ? "Start using SmartEars" : "Continue")
                .font(SETheme.Typography.button)
                .frame(maxWidth: .infinity)
                .padding()
                .background(SETheme.Colors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: SETheme.Radius.card, style: .continuous))
        }
        .padding(SETheme.Spacing.large)
    }

    private func advance() {
        if page < 2 {
            withAnimation { page += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        let trimmed = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { env.wakeWord.setWakePhrase(trimmed) }
        env.hasCompletedOnboarding = true
        dismiss()
    }

    // MARK: Permission requests (real system APIs)

    private func requestMic() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in micGranted = granted }
        }
    }

    private func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in speechGranted = (status == .authorized) }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                Task { @MainActor in notificationsGranted = granted }
            }
    }
}

// MARK: - Building blocks

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: SETheme.Spacing.medium) {
                Image(systemName: symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(SETheme.Colors.accent)
                    .padding(.top, SETheme.Spacing.xLarge)
                Text(title)
                    .font(SETheme.Typography.largeTitle)
                    .foregroundStyle(SETheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(SETheme.Typography.subheadline)
                    .foregroundStyle(SETheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                content
            }
            .padding(.horizontal, SETheme.Spacing.large)
            .padding(.bottom, SETheme.Spacing.xLarge)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: SETheme.Spacing.medium) {
            Image(systemName: symbol)
                .foregroundStyle(SETheme.Colors.accent)
                .frame(width: 28)
            Text(text)
                .font(SETheme.Typography.body)
                .foregroundStyle(SETheme.Colors.textPrimary)
            Spacer()
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: SETheme.Spacing.medium) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(SETheme.Colors.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SETheme.Typography.headline)
                    .foregroundStyle(SETheme.Colors.textPrimary)
                Text(detail)
                    .font(SETheme.Typography.caption)
                    .foregroundStyle(SETheme.Colors.textSecondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SETheme.Colors.success)
            } else {
                Button("Allow", action: action)
                    .font(SETheme.Typography.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(SETheme.Colors.accent)
            }
        }
        .seCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail). \(granted ? "Granted" : "Not granted")")
    }
}

/// A simple wrapping row of selectable suggestion chips.
private struct FlexibleChips: View {
    let items: [String]
    let selection: String
    let onTap: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: SETheme.Spacing.small)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: SETheme.Spacing.small) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item)
                        .font(SETheme.Typography.caption)
                        .padding(.horizontal, SETheme.Spacing.medium)
                        .padding(.vertical, SETheme.Spacing.small)
                        .frame(maxWidth: .infinity)
                        .background(
                            (item == selection ? SETheme.Colors.accent : SETheme.Colors.surface)
                                .opacity(item == selection ? 1 : 0.6)
                        )
                        .foregroundStyle(item == selection ? .white : SETheme.Colors.textPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    OnboardingView().environmentObject(AppEnvironment())
}
