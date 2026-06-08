import SwiftUI

// MARK: - AlertsView (recent alerts)
//
// A list of recent `AlertItem`s with their spoken summary. The Alerting engine
// produces these (an audio chime + a spoken summary) from inbound
// messages/emails that pass the user's `TriggerConfig`.
//
// Apple-platform honesty: third-party apps CANNOT silently read the SMS/iMessage
// database or arbitrary Mail.app content. Real inbound items therefore originate
// from `UNUserNotificationCenter` content the user routes to us, the Gmail API
// (the only third-party path with full bodies), or a user-driven share — never
// from reading the system Messages DB. The mock build surfaces `.simulated` data.

struct AlertsView: View {
    @EnvironmentObject private var env: AppEnvironment

    /// Newest alerts first.
    private var sortedAlerts: [AlertItem] {
        env.alerts.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ZStack {
            SETheme.Colors.background.ignoresSafeArea()

            if !env.smartAlertingEnabled {
                ContentUnavailableView(
                    "Smart alerting is off",
                    systemImage: "bell.slash",
                    description: Text("Turn on smart alerting in Settings to hear important messages and emails.")
                )
            } else if sortedAlerts.isEmpty {
                ContentUnavailableView(
                    "No recent alerts",
                    systemImage: "bell",
                    description: Text("Important messages and emails will appear here with a spoken summary.")
                )
            } else {
                List {
                    Section {
                        ForEach(sortedAlerts) { alert in
                            AlertRow(alert: alert) { speak(alert) }
                        }
                    } footer: {
                        Text("Inbound items come from notifications you route to SmartEars, the Gmail API, or shares — third-party apps can't read the system Messages database.")
                            .font(SETheme.Typography.caption)
                            .foregroundStyle(SETheme.Colors.textSecondary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !sortedAlerts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        withAnimation { env.alerts.removeAll() }
                    }
                    .foregroundStyle(SETheme.Colors.danger)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Speaks the alert summary aloud (the primary output surface for SmartEars)
    /// and marks the alert acknowledged.
    private func speak(_ alert: AlertItem) {
        if let idx = env.alerts.firstIndex(where: { $0.id == alert.id }) {
            env.alerts[idx].acknowledged = true
        }
        Task {
            await env.chime.playAlertChime(importance: alert.importance)
            await env.speechSynthesizer.speak(alert.spokenSummary)
        }
    }
}

// MARK: - AlertRow

private struct AlertRow: View {
    let alert: AlertItem
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SETheme.Spacing.medium) {
            Image(systemName: categorySymbol)
                .font(.title3)
                .foregroundStyle(importanceColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(alert.title)
                        .font(SETheme.Typography.headline)
                        .foregroundStyle(SETheme.Colors.textPrimary)
                        .lineLimit(1)
                    if !alert.acknowledged {
                        Circle()
                            .fill(SETheme.Colors.accent)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                    Spacer()
                    Text(alert.createdAt, style: .time)
                        .font(SETheme.Typography.caption)
                        .foregroundStyle(SETheme.Colors.textSecondary)
                }

                Text(alert.spokenSummary)
                    .font(SETheme.Typography.subheadline)
                    .foregroundStyle(SETheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                importanceBadge
            }

            Button(action: onPlay) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title3)
                    .foregroundStyle(SETheme.Colors.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play spoken summary")
        }
        .padding(.vertical, 4)
        .listRowBackground(SETheme.Colors.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.title), \(importanceText) importance. \(alert.spokenSummary)")
    }

    private var importanceBadge: some View {
        Text(importanceText.uppercased())
            .font(SETheme.Typography.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(importanceColor.opacity(0.18))
            .foregroundStyle(importanceColor)
            .clipShape(Capsule())
    }

    private var categorySymbol: String {
        switch alert.category {
        case .message: return "message.fill"
        case .email: return "envelope.fill"
        case .system: return "gearshape.fill"
        }
    }

    private var importanceColor: Color {
        switch alert.importance {
        case .low: return SETheme.Colors.textSecondary
        case .normal: return SETheme.Colors.accent
        case .high: return SETheme.Colors.warning
        case .urgent: return SETheme.Colors.danger
        }
    }

    private var importanceText: String {
        switch alert.importance {
        case .low: return "low"
        case .normal: return "normal"
        case .high: return "high"
        case .urgent: return "urgent"
        }
    }
}

#Preview {
    NavigationStack { AlertsView().environmentObject(AppEnvironment()) }
}
