import SwiftUI

// MARK: - ConversationView (transcript history)
//
// A scrollable transcript of the conversation history. SmartEars is voice-first,
// so this is a review surface for turns that already happened — each
// `AssistantResponse` in `AppEnvironment.history` is rendered as a card with its
// spoken text, optional display card, and any pending confirmation read-back.
//
// `history` is newest-first (the voice turn inserts at index 0), so we display it
// in chronological order (oldest at top) and auto-scroll to the latest turn,
// matching how a chat transcript reads.

struct ConversationView: View {
    @EnvironmentObject private var env: AppEnvironment

    /// Chronological order (oldest first) for natural top-to-bottom reading.
    private var turns: [AssistantResponse] { env.history.reversed() }

    var body: some View {
        ZStack {
            SETheme.Colors.background.ignoresSafeArea()

            if turns.isEmpty {
                ContentUnavailableView(
                    "No conversation yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Tap the orb on the home screen to ask about the weather, a stock, or the news.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: SETheme.Spacing.medium) {
                            ForEach(turns) { turn in
                                ConversationTurnCard(response: turn)
                                    .id(turn.id)
                            }
                        }
                        .padding(SETheme.Spacing.large)
                    }
                    .onAppear { scrollToLatest(proxy) }
                    .onChange(of: env.history.count) { _, _ in scrollToLatest(proxy) }
                }
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = turns.last else { return }
        withAnimation(.easeOut) { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

// MARK: - ConversationTurnCard

private struct ConversationTurnCard: View {
    let response: AssistantResponse

    var body: some View {
        VStack(alignment: .leading, spacing: SETheme.Spacing.small) {
            HStack(spacing: SETheme.Spacing.small) {
                Image(systemName: cardSymbol)
                    .foregroundStyle(SETheme.Colors.accent)
                Text(response.displayCard?.title ?? "SmartEars")
                    .font(SETheme.Typography.headline)
                    .foregroundStyle(SETheme.Colors.textPrimary)
                Spacer()
                Text(response.createdAt, style: .time)
                    .font(SETheme.Typography.caption)
                    .foregroundStyle(SETheme.Colors.textSecondary)
            }

            if let subtitle = response.displayCard?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SETheme.Typography.subheadline)
                    .foregroundStyle(SETheme.Colors.textSecondary)
            }

            Text(response.spokenText)
                .font(SETheme.Typography.body)
                .foregroundStyle(SETheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let body = response.displayCard?.body,
               !body.isEmpty,
               body != response.spokenText {
                Text(body)
                    .font(SETheme.Typography.subheadline)
                    .foregroundStyle(SETheme.Colors.textSecondary)
            }

            if let pending = response.pendingConfirmation {
                Label(pending.readbackText, systemImage: "checkmark.shield")
                    .font(SETheme.Typography.caption)
                    .foregroundStyle(SETheme.Colors.warning)
            }

            if response.followUpExpected {
                Label("Follow-up expected", systemImage: "arrow.turn.down.right")
                    .font(SETheme.Typography.caption)
                    .foregroundStyle(SETheme.Colors.accentSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .seCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(response.displayCard?.title ?? "SmartEars"): \(response.spokenText)")
    }

    private var cardSymbol: String {
        switch response.displayCard?.kind {
        case .weather: return "cloud.sun.fill"
        case .stock: return "chart.line.uptrend.xyaxis"
        case .news: return "newspaper.fill"
        case .alert: return "exclamationmark.bubble.fill"
        case .email: return "envelope.fill"
        case .system: return "gearshape.fill"
        case .conversation, .none: return "bubble.left.and.bubble.right.fill"
        }
    }
}

#Preview {
    let env = AppEnvironment()
    env.history = [
        AssistantResponse(
            spokenText: "It's 70°F and partly cloudy in Bozeman, MT.",
            displayCard: DisplayCard(kind: .weather, title: "Bozeman, MT", subtitle: "Partly cloudy"),
            followUpExpected: true
        ),
        AssistantResponse(
            spokenText: "AAPL is at $213.42, up 0.88%.",
            displayCard: DisplayCard(kind: .stock, title: "AAPL")
        )
    ]
    return NavigationStack { ConversationView().environmentObject(env) }
}
