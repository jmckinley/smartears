import Foundation
import SwiftUI

// MARK: - AppEnvironment (dependency container)
//
// `AppEnvironment` is the single ObservableObject dependency container injected
// into the SwiftUI environment. It exposes EVERY service protocol from
// Models.swift. By DEFAULT it wires the bundled stub/mock implementations
// defined at the bottom of this file, so the app COMPILES AND RUNS WITH NO
// SECRETS PRESENT. A real `ServiceFactory` (Voice/Assistant/Comms modules) can
// later swap in network-backed implementations when a credential resolves from
// `AppConfig.load()` — without changing any call site.
//
// Apple-platform honesty (mirrored from Models.swift):
//  * SMS/iMessage and Apple Mail are compose-only (user taps Send). The stub
//    `MessageComposeService` therefore throws `.userActionRequired`.
//  * Inbound SMS bodies are generally NOT readable; the stub inbox returns
//    `.simulated` sample data with that provenance.

@MainActor
public final class AppEnvironment: ObservableObject {

    // Resolved configuration (credentials are absent in dev -> mocks used).
    public let config: AppConfig

    // MARK: Service protocol surface (defaults to stubs/mocks)
    public let llm: any LLMService
    public let weather: any WeatherService
    public let stocks: any StockService
    public let news: any NewsService
    public let messageCompose: any MessageComposeService
    public let messageInbox: any MessageInboxService
    public let email: any EmailService
    public let contacts: any ContactResolving
    public let speechRecognizer: any SpeechRecognizing
    public let speechSynthesizer: any SpeechSynthesizing
    public let wakeWord: any WakeWordEngine
    public let gestures: any GestureService
    public let chime: any ChimeService
    public let toolRouter: any ToolRouting

    // MARK: Lightweight observable app state for the minimal UI surface.
    @Published public var voiceState: VoiceSessionState = .idle
    @Published public var history: [AssistantResponse] = []
    @Published public var triggerConfig: TriggerConfig = .default

    /// Live (partial) transcript shown while listening. Cleared between turns.
    @Published public var liveTranscript: String = ""
    /// The most recent assistant response (mirror of `history.first`) for glance.
    @Published public var lastResponse: AssistantResponse?
    /// Recent surfaced alerts (chime + spoken summary). Newest first.
    @Published public var alerts: [AlertItem] = AppEnvironment.sampleAlerts
    /// Master toggle for the smart-alerting engine.
    @Published public var smartAlertingEnabled: Bool = true
    /// Which information sources the user has enabled (Settings -> Sources).
    @Published public var enabledInfoSources: Set<InfoSource> = Set(InfoSource.allCases)
    /// Whether the user has completed onboarding (drives presentation in RootView).
    @Published public var hasCompletedOnboarding: Bool = false

    /// Info sources the user can toggle on/off in Settings. These mirror the
    /// service protocol surface (weather/stocks/news/email) plus inbound messages.
    public enum InfoSource: String, CaseIterable, Identifiable, Codable, Sendable {
        case weather, stocks, news, email, messages
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .weather: return "Weather"
            case .stocks: return "Stocks"
            case .news: return "News"
            case .email: return "Email (Gmail)"
            case .messages: return "Messages"
            }
        }
        public var systemImage: String {
            switch self {
            case .weather: return "cloud.sun.fill"
            case .stocks: return "chart.line.uptrend.xyaxis"
            case .news: return "newspaper.fill"
            case .email: return "envelope.fill"
            case .messages: return "message.fill"
            }
        }
    }

    /// Sample alerts so the Alerts surface is populated on the mock build.
    static let sampleAlerts: [AlertItem] = [
        AlertItem(
            category: .message,
            title: "Mom",
            spokenSummary: "Mom texted: Call me when you get a sec.",
            importance: .high
        ),
        AlertItem(
            category: .email,
            title: "Jordan Lee — Q3 planning doc",
            spokenSummary: "Important email from Jordan Lee about the Q3 planning doc.",
            importance: .high
        )
    ]

    /// Designated initializer. All dependencies default to stub/mock impls so a
    /// no-argument construction yields a fully runnable, secret-free app.
    public init(
        config: AppConfig = .load(),
        llm: (any LLMService)? = nil,
        weather: (any WeatherService)? = nil,
        stocks: (any StockService)? = nil,
        news: (any NewsService)? = nil,
        messageCompose: (any MessageComposeService)? = nil,
        messageInbox: (any MessageInboxService)? = nil,
        email: (any EmailService)? = nil,
        contacts: (any ContactResolving)? = nil,
        speechRecognizer: (any SpeechRecognizing)? = nil,
        speechSynthesizer: (any SpeechSynthesizing)? = nil,
        wakeWord: (any WakeWordEngine)? = nil,
        gestures: (any GestureService)? = nil,
        chime: (any ChimeService)? = nil,
        toolRouter: (any ToolRouting)? = nil
    ) {
        self.config = config
        self.llm = llm ?? StubLLMService()
        self.weather = weather ?? StubWeatherService()
        self.stocks = stocks ?? StubStockService()
        self.news = news ?? StubNewsService()
        self.messageCompose = messageCompose ?? StubMessageComposeService()
        self.messageInbox = messageInbox ?? StubMessageInboxService()
        self.email = email ?? StubEmailService()
        self.contacts = contacts ?? StubContactResolver()
        self.speechRecognizer = speechRecognizer ?? StubSpeechRecognizer()
        self.speechSynthesizer = speechSynthesizer ?? StubSpeechSynthesizer()
        self.wakeWord = wakeWord ?? StubWakeWordEngine()
        self.gestures = gestures ?? StubGestureService()
        self.chime = chime ?? StubChimeService()
        // The default router depends on the resolved info/comms services above.
        self.toolRouter = toolRouter ?? StubToolRouter(
            weather: self.weather,
            stocks: self.stocks,
            news: self.news,
            llm: self.llm
        )
    }

    /// Convenience flag for the UI: are we running entirely on mock services?
    public var isUsingMockServices: Bool {
        !(config.hasCredential(config.llmAPIKey)
          || config.hasCredential(config.weatherAPIKey)
          || config.hasCredential(config.stocksAPIKey)
          || config.hasCredential(config.newsAPIKey)
          || config.hasCredential(config.gmailClientID))
    }

    /// Stores an API key the user pasted in Settings.
    ///
    /// SECURITY: This is a PLACEHOLDER. A real build MUST persist credentials to
    /// the iOS Keychain (Keychain Services / `kSecClassGenericPassword`) — NEVER
    /// in source, UserDefaults, or this in-memory map. No secret is ever written
    /// to disk here; we only retain it for the current process so a real service
    /// could be swapped in via `ServiceFactory`.
    /// TODO: Replace with a Keychain-backed `CredentialStore` (Keychain Services).
    @Published public private(set) var pendingCredentials: [CredentialSlot: Bool] = [:]
    private var inMemoryCredentials: [CredentialSlot: String] = [:]

    public enum CredentialSlot: String, CaseIterable, Identifiable, Sendable {
        case llm, weather, stocks, news, gmail
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .llm: return "LLM API Key"
            case .weather: return "Weather API Key"
            case .stocks: return "Stocks API Key"
            case .news: return "News API Key"
            case .gmail: return "Gmail Client ID"
            }
        }
        /// The Info.plist key this credential would resolve to in a real build.
        public var infoPlistKey: String {
            switch self {
            case .llm: return "SE_LLM_API_KEY"
            case .weather: return "SE_WEATHER_API_KEY"
            case .stocks: return "SE_STOCKS_API_KEY"
            case .news: return "SE_NEWS_API_KEY"
            case .gmail: return "SE_GMAIL_CLIENT_ID"
            }
        }
    }

    /// Returns whether a credential slot currently has a value resolved
    /// (from config at launch, or pasted this session).
    public func hasCredential(for slot: CredentialSlot) -> Bool {
        if pendingCredentials[slot] == true { return true }
        switch slot {
        case .llm: return config.hasCredential(config.llmAPIKey)
        case .weather: return config.hasCredential(config.weatherAPIKey)
        case .stocks: return config.hasCredential(config.stocksAPIKey)
        case .news: return config.hasCredential(config.newsAPIKey)
        case .gmail: return config.hasCredential(config.gmailClientID)
        }
    }

    /// Saves a pasted credential (placeholder; see SECURITY note above).
    public func saveCredential(_ value: String, for slot: CredentialSlot) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // TODO: write `trimmed` to the Keychain under `slot.infoPlistKey`.
        inMemoryCredentials[slot] = trimmed
        pendingCredentials[slot] = true
    }

    /// Clears a pasted credential from the in-memory placeholder store.
    public func clearCredential(for slot: CredentialSlot) {
        // TODO: delete the Keychain item for `slot.infoPlistKey`.
        inMemoryCredentials[slot] = nil
        pendingCredentials[slot] = nil
    }
}

// MARK: - Stub / Mock Service Implementations
//
// These return realistic sample data so the app is fully runnable without keys.
// Real network-backed implementations live in their respective Service modules
// and are swapped in by a ServiceFactory when credentials resolve.

struct StubLLMService: LLMService {
    func complete(prompt: String, context: [String]) async throws -> String {
        "Here's what I found about \"\(prompt)\". (Running on the bundled mock LLM — no API key configured.)"
    }
    func classifyIntent(transcript: String) async throws -> AssistantIntent {
        let lower = transcript.lowercased()
        if lower.contains("weather") { return .weather(location: nil) }
        if lower.contains("news") { return .news(topic: nil) }
        if lower.contains("stock") || lower.contains("price") { return .stock(symbol: "AAPL") }
        return .conversational(prompt: transcript)
    }
}

// NOTE: `StubWeatherService`, `StubStockService`, and `StubNewsService` are
// defined in their respective Service files (Services/Info/*.swift) with richer
// sample data. They are reused here rather than redeclared.

struct StubMessageComposeService: MessageComposeService {
    // Honest: SMS/iMessage are compose-only. The real impl presents
    // MFMessageComposeViewController; the user must tap Send. We model that as
    // `userActionRequired` so callers never assume an auto-send happened.
    func compose(channel: MessageChannel, recipient: String?, body: String?) async throws {
        throw SmartEarsError.userActionRequired(
            "Opening the compose sheet for \(recipient ?? "your contact") — tap Send to deliver."
        )
    }
}

struct StubMessageInboxService: MessageInboxService {
    func recentMessages(filter: AlertFilter) async throws -> [MessageSummary] {
        [
            MessageSummary(
                channel: .sms, source: .simulated, senderName: "Mom",
                preview: "Call me when you get a sec", importance: .high
            ),
            MessageSummary(
                channel: .sms, source: .userNotification, senderName: "Alex",
                preview: "Lunch at noon?", importance: .normal, isRead: true
            )
        ]
    }
}

struct StubEmailService: EmailService {
    func recentEmails(filter: AlertFilter) async throws -> [EmailSummary] {
        [
            EmailSummary(
                source: .simulated, from: "Jordan Lee", fromAddress: "jordan@example.com",
                subject: "Q3 planning doc", snippet: "Adding you to the review thread…",
                importance: .high
            )
        ]
    }
    func sendEmail(recipient: String, subject: String, body: String) async throws {
        // With Gmail creds the real impl sends via the API. Without creds, the
        // app falls back to MFMailComposeViewController -> user taps Send.
        throw SmartEarsError.userActionRequired(
            "Opening the mail compose sheet to \(recipient) — tap Send to deliver."
        )
    }
}

struct StubContactResolver: ContactResolving {
    func resolve(name: String) async throws -> ResolvedContact? {
        ResolvedContact(displayName: name, phoneNumber: "+15555550123", emailAddress: nil)
    }
}

struct StubSpeechRecognizer: SpeechRecognizing {
    func transcribe() -> AsyncThrowingStream<Transcription, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Transcription(text: "what's the weather", isFinal: false, confidence: 0.6))
            continuation.yield(Transcription(text: "what's the weather", isFinal: true))
            continuation.finish()
        }
    }
}

actor StubSpeechSynthesizer: SpeechSynthesizing {
    // Real impl wraps AVSpeechSynthesizer; the stub is a no-op so previews/tests
    // don't require audio hardware.
    func speak(_ text: String) async { /* no-op stub */ }
    func stop() async { /* no-op stub */ }
}

struct StubWakeWordEngine: WakeWordEngine {
    func wakeEvents() -> AsyncStream<Date> {
        // Stub never auto-fires; the real engine uses SFSpeechRecognizer phrase
        // matching. Fully-custom on-device keyword spotting is limited on iOS.
        AsyncStream { _ in }
    }
    func setWakePhrase(_ phrase: String) { /* no-op stub */ }
}

struct StubGestureService: GestureService {
    func gestureEvents() -> AsyncStream<GestureEvent> {
        // Real impl bridges MPRemoteCommandCenter / route changes /
        // CMHeadphoneMotionManager. Stub emits nothing.
        AsyncStream { _ in }
    }
}

actor StubChimeService: ChimeService {
    func playWakeChime() async { /* no-op stub */ }
    func playAlertChime(importance: Importance) async { /* no-op stub */ }
}

/// A minimal router so the app produces real `AssistantResponse`s end-to-end on
/// mocks. The full `ToolRouter` (Assistant module) handles every intent + builds
/// `PendingConfirmation` for sends.
struct StubToolRouter: ToolRouting {
    let weather: any WeatherService
    let stocks: any StockService
    let news: any NewsService
    let llm: any LLMService

    func route(_ intent: AssistantIntent) async -> AssistantResponse {
        do {
            switch intent {
            case .weather(let location):
                let w = try await weather.currentWeather(location: location)
                let text = "It's \(Int(w.temperatureF.rounded()))°F and \(w.conditionDescription) in \(w.locationName)."
                return AssistantResponse(
                    spokenText: text,
                    displayCard: DisplayCard(kind: .weather, title: w.locationName, subtitle: text),
                    followUpExpected: true
                )
            case .stock(let symbol):
                let q = try await stocks.quote(symbol: symbol)
                let dir = q.isUp ? "up" : "down"
                let text = "\(q.symbol) is at $\(String(format: "%.2f", q.price)), \(dir) \(String(format: "%.2f", abs(q.changePercent)))%."
                return AssistantResponse(
                    spokenText: text,
                    displayCard: DisplayCard(kind: .stock, title: q.symbol, subtitle: text)
                )
            case .news(let topic):
                let items = try await news.headlines(topic: topic, limit: 3)
                let text = "Top headlines: " + items.map(\.headline).joined(separator: "; ") + "."
                return AssistantResponse(
                    spokenText: text,
                    displayCard: DisplayCard(kind: .news, title: "News", body: text)
                )
            case .conversational(let prompt), .unknown(let prompt):
                let reply = try await llm.complete(prompt: prompt, context: [])
                return AssistantResponse(
                    spokenText: reply,
                    displayCard: DisplayCard(kind: .conversation, title: "SmartEars", body: reply),
                    followUpExpected: true
                )
            default:
                return AssistantResponse(
                    spokenText: "I can't do that yet on the mock build, but I heard you.",
                    displayCard: DisplayCard(kind: .system, title: "Not yet supported")
                )
            }
        } catch let error as SmartEarsError {
            return AssistantResponse(
                spokenText: error.localizedDescription,
                displayCard: DisplayCard(kind: .system, title: "Action needed", body: error.localizedDescription)
            )
        } catch {
            return AssistantResponse(spokenText: "Sorry, something went wrong.")
        }
    }
}
