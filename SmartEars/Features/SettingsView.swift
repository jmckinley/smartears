import SwiftUI

// MARK: - SettingsView
//
// Configures the assistant: the trigger/wake word (`TriggerConfig` + the
// WakeWordEngine phrase), smart-alerting behavior, VIP senders, which info
// sources are enabled, and where to paste API keys.
//
// SECURITY: API keys are NEVER stored in source. The paste fields hand the value
// to `AppEnvironment.saveCredential(_:for:)`, a Keychain PLACEHOLDER (see that
// method). A real build persists to the iOS Keychain (Keychain Services); the
// field never shows or logs the secret and is cleared from the UI after saving.

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    /// Local editable copy of the wake phrase; committed to the engine on change.
    @State private var wakePhrase: String = ""
    @State private var newVIP: String = ""

    var body: some View {
        Form {
            triggerSection
            airPodSection
            alertingSection
            vipSection
            sourcesSection
            credentialsSection
        }
        .scrollContentBackground(.hidden)
        .background(SETheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear { if wakePhrase.isEmpty { wakePhrase = env.wakePhrase } }
    }

    // MARK: Trigger / wake word

    private var triggerSection: some View {
        Section {
            HStack {
                Image(systemName: "waveform.badge.mic")
                    .foregroundStyle(SETheme.Colors.accent)
                TextField("Wake phrase", text: $wakePhrase)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onSubmit(commitWakePhrase)
            }
            Picker("Minimum alert importance", selection: $env.triggerConfig.minimumImportance) {
                Text("Normal").tag(Importance.normal)
                Text("High").tag(Importance.high)
                Text("Urgent").tag(Importance.urgent)
            }
            Toggle("Read full body aloud", isOn: $env.triggerConfig.readFullBody)
        } header: {
            Text("Trigger / Wake Word")
        } footer: {
            Text("Today SmartEars is tap-to-talk: tap the orb to start a turn. A hands-free wake word is coming soon (opt-in); this phrase is saved for when it ships. iOS doesn't allow fully-custom always-on keyword models for third-party apps, so it'll match on-device via speech recognition.")
        }
    }

    // MARK: AirPod tap to talk

    private var airPodSection: some View {
        Section {
            Toggle(isOn: $env.airPodTapControlEnabled) {
                Label("AirPod tap to talk", systemImage: "airpods")
            }
            .tint(SETheme.Colors.accent)
        } header: {
            Text("AirPods")
        } footer: {
            Text("When on, single-tap an AirPod to start talking (no wake word) and double-tap to interrupt a reply. To catch a tap instantly, SmartEars becomes your iPhone's \u{201C}now playing\u{201D} app while it's open, so a tap talks to SmartEars instead of controlling your music. The moment you leave SmartEars, your taps go back to your music. We don't lower or pause your music just for listening — only an actual request ducks it briefly. Turn this off to keep your taps on music and use the on-screen orb instead.")
        }
    }

    // MARK: Smart alerting

    private var alertingSection: some View {
        Section {
            Toggle(isOn: $env.smartAlertingEnabled) {
                Label("Smart alerting", systemImage: "bell.badge")
            }
            .tint(SETheme.Colors.accent)
        } header: {
            Text("Alerting")
        } footer: {
            Text("When on, important messages and emails play a chime and a spoken summary.")
        }
    }

    // MARK: VIP senders

    private var vipSection: some View {
        Section {
            ForEach(env.triggerConfig.vipSenders, id: \.self) { sender in
                HStack {
                    Image(systemName: "star.fill").foregroundStyle(SETheme.Colors.warning)
                    Text(sender)
                }
            }
            .onDelete(perform: deleteVIP)

            HStack {
                TextField("Add a VIP sender", text: $newVIP)
                    .textInputAutocapitalization(.words)
                    .onSubmit(addVIP)
                Button(action: addVIP) {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newVIP.trimmingCharacters(in: .whitespaces).isEmpty)
                .foregroundStyle(SETheme.Colors.accent)
            }
        } header: {
            Text("VIP Senders")
        } footer: {
            Text("VIPs always alert you regardless of the minimum importance.")
        }
    }

    // MARK: Info sources

    private var sourcesSection: some View {
        Section {
            ForEach(AppEnvironment.InfoSource.allCases) { source in
                Toggle(isOn: bindingForSource(source)) {
                    Label(source.displayName, systemImage: source.systemImage)
                }
                .tint(SETheme.Colors.accent)
            }
        } header: {
            Text("Information Sources")
        } footer: {
            Text("Disable a source to stop SmartEars from using it for answers and alerts.")
        }
    }

    // MARK: Credentials (Keychain placeholder)

    private var credentialsSection: some View {
        Section {
            ForEach(AppEnvironment.CredentialSlot.allCases) { slot in
                CredentialField(
                    slot: slot,
                    isConfigured: env.hasCredential(for: slot),
                    onSave: { env.saveCredential($0, for: slot) },
                    onClear: { env.clearCredential(for: slot) }
                )
            }
        } header: {
            Text("AI & Accounts")
        } footer: {
            Text("Weather, stocks, and news work for free with no setup (Open-Meteo, Yahoo Finance, Google News). Only “ask the AI” needs a key. Anything you enter is stored in the device Keychain — never in source, iCloud, or backups.")
        }
    }

    // MARK: Helpers

    private func commitWakePhrase() {
        let trimmed = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wakePhrase = trimmed
        env.updateWakePhrase(trimmed)   // sets engine + persists via wakePhrase didSet
    }

    private func addVIP() {
        let trimmed = newVIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !env.triggerConfig.vipSenders.contains(trimmed) else { return }
        env.triggerConfig.vipSenders.append(trimmed)
        newVIP = ""
    }

    private func deleteVIP(at offsets: IndexSet) {
        env.triggerConfig.vipSenders.remove(atOffsets: offsets)
    }

    private func bindingForSource(_ source: AppEnvironment.InfoSource) -> Binding<Bool> {
        Binding(
            get: { env.enabledInfoSources.contains(source) },
            set: { isOn in
                if isOn { env.enabledInfoSources.insert(source) }
                else { env.enabledInfoSources.remove(source) }
            }
        )
    }
}

// MARK: - CredentialField
//
// A single secure paste field for an API key. Shows a "Configured" state when a
// credential already resolves; the entered value is handed to the Keychain
// placeholder and cleared from the field on save (never displayed back).

private struct CredentialField: View {
    let slot: AppEnvironment.CredentialSlot
    let isConfigured: Bool
    let onSave: (String) -> Void
    let onClear: () -> Void

    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SETheme.Spacing.small) {
            HStack {
                Text(slot.displayName)
                    .font(SETheme.Typography.body)
                Spacer()
                if isConfigured {
                    Label("Configured", systemImage: "checkmark.seal.fill")
                        .font(SETheme.Typography.caption)
                        .foregroundStyle(SETheme.Colors.success)
                }
            }

            Text(slot.hint)
                .font(SETheme.Typography.caption)
                .foregroundStyle(SETheme.Colors.textSecondary)

            HStack {
                SecureField(slot == .gmail ? "Paste OAuth token" : "Paste API key", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))

                if isConfigured {
                    Button(role: .destructive) {
                        value = ""
                        onClear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(SETheme.Colors.danger)
                } else {
                    Button {
                        onSave(value)
                        value = ""
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(SETheme.Colors.accent)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { SettingsView().environmentObject(AppEnvironment()) }
}
