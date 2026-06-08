import SwiftUI

// MARK: - SmartEars Design System
//
// A small, audio-first design system. Because SmartEars is voice-primary, the
// visual surface is intentionally minimal: a calm palette, a clear type scale,
// and one signature component — the `AudioWaveformView` listening indicator that
// reflects `VoiceSessionState`.

public enum SETheme {

    // MARK: Colors
    public enum Colors {
        /// Brand accent — used for the waveform, primary actions, AirPods glyph.
        public static let accent = Color(red: 0.36, green: 0.42, blue: 0.95)
        public static let accentSecondary = Color(red: 0.55, green: 0.40, blue: 0.95)

        public static let background = Color(uiColor: .systemBackground)
        public static let surface = Color(uiColor: .secondarySystemBackground)

        public static let textPrimary = Color(uiColor: .label)
        public static let textSecondary = Color(uiColor: .secondaryLabel)

        public static let success = Color(red: 0.20, green: 0.70, blue: 0.45)
        public static let warning = Color(red: 0.90, green: 0.62, blue: 0.10)
        public static let danger = Color(red: 0.86, green: 0.25, blue: 0.25)

        /// Maps a voice session state to the waveform tint.
        public static func tint(for state: VoiceSessionState) -> Color {
            switch state {
            case .idle: return textSecondary
            case .waking: return accentSecondary
            case .listening: return accent
            case .thinking: return accentSecondary
            case .speaking: return success
            case .awaitingFollowUp: return accent
            }
        }
    }

    // MARK: Typography
    public enum Typography {
        public static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
        public static let title = Font.system(.title2, design: .rounded, weight: .semibold)
        public static let headline = Font.system(.headline, design: .rounded, weight: .semibold)
        public static let subheadline = Font.system(.subheadline, design: .rounded)
        public static let body = Font.system(.body, design: .rounded)
        public static let button = Font.system(.headline, design: .rounded, weight: .semibold)
        public static let caption = Font.system(.caption, design: .rounded, weight: .semibold)
    }

    // MARK: Spacing
    public enum Spacing {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 16
        public static let large: CGFloat = 24
        public static let xLarge: CGFloat = 40
    }

    // MARK: Radius
    public enum Radius {
        public static let card: CGFloat = 16
        public static let pill: CGFloat = 999
    }
}

// MARK: - AudioWaveformView (listening indicator)
//
// The signature component: animated vertical bars that visualize the assistant's
// state. Idle = still/flat; listening/speaking = animated. Driven purely by
// `VoiceSessionState` so it stays decoupled from real audio levels (a real impl
// could feed live mic RMS into `levelOverride`).

public struct AudioWaveformView: View {
    public let state: VoiceSessionState
    public var barCount: Int
    /// Optional live audio level (0...1). When nil, animation is state-driven.
    public var levelOverride: CGFloat?

    @State private var phase: CGFloat = 0

    public init(state: VoiceSessionState, barCount: Int = 5, levelOverride: CGFloat? = nil) {
        self.state = state
        self.barCount = barCount
        self.levelOverride = levelOverride
    }

    private var isActive: Bool {
        switch state {
        case .listening, .speaking, .thinking, .waking, .awaitingFollowUp: return true
        case .idle: return false
        }
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: SETheme.Spacing.small) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(SETheme.Colors.tint(for: state))
                        .frame(width: 8, height: barHeight(index: index, time: t))
                        .animation(.easeInOut(duration: 0.12), value: isActive)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
        }
    }

    /// Computes a bar's height from either a live level or a phase-shifted sine
    /// wave so neighboring bars ripple out of phase.
    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let minH: CGFloat = 10
        let maxH: CGFloat = 72
        guard isActive else { return minH }
        if let level = levelOverride {
            let jitter = sin(CGFloat(index) * 1.3) * 0.15
            let scaled = max(0, min(1, level + jitter))
            return minH + (maxH - minH) * scaled
        }
        let speed: CGFloat = state == .thinking ? 4.5 : 7.0
        let offset = CGFloat(index) * 0.6
        let wave = (sin(CGFloat(time) * speed + offset) + 1) / 2  // 0...1
        return minH + (maxH - minH) * wave
    }

    private var accessibilityDescription: String {
        switch state {
        case .idle: return "Idle"
        case .waking: return "Waking"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .awaitingFollowUp: return "Waiting for a follow-up"
        }
    }
}

// MARK: - Reusable styling helpers

public extension View {
    /// Standard SmartEars card container.
    func seCard() -> some View {
        self
            .padding(SETheme.Spacing.medium)
            .background(SETheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: SETheme.Radius.card, style: .continuous))
    }
}

#Preview("Waveform states") {
    VStack(spacing: 32) {
        AudioWaveformView(state: .idle)
        AudioWaveformView(state: .listening)
        AudioWaveformView(state: .speaking)
    }
    .padding()
}
