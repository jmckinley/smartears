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

    // Resolved configuration. Credentials resolve from (in priority order) the
    // Keychain (keys the user pasted in Settings) then Info.plist placeholders.
    public let config: AppConfig

    /// Secure persistence for user-entered API keys (real Keychain by default).
    public let credentialStore: any CredentialStoring

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
        config: AppConfig? = nil,
        credentialStore: (any CredentialStoring)? = nil,
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
        // Resolve the credential store first, then merge any Keychain-stored keys
        // over the Info.plist-derived config so persisted user keys win.
        let store = credentialStore ?? KeychainCredentialStore()
        self.credentialStore = store
        let base = config ?? .load()
        self.config = AppConfig(
            llmAPIKey: store.value(for: "SE_LLM_API_KEY") ?? base.llmAPIKey,
            weatherAPIKey: store.value(for: "SE_WEATHER_API_KEY") ?? base.weatherAPIKey,
            stocksAPIKey: store.value(for: "SE_STOCKS_API_KEY") ?? base.stocksAPIKey,
            newsAPIKey: store.value(for: "SE_NEWS_API_KEY") ?? base.newsAPIKey,
            gmailClientID: store.value(for: "SE_GMAIL_CLIENT_ID") ?? base.gmailClientID
        )
        // Surface which slots already hold a key so Settings shows "Configured"
        // across launches.
        self.pendingCredentials = Dictionary(
            uniqueKeysWithValues: CredentialSlot.allCases
                .filter { store.value(for: $0.infoPlistKey) != nil }
                .map { ($0, true) }
        )
        // Build the real services. Each can still be overridden via the matching
        // initializer parameter (for tests/previews) using the `?? realImpl`
        // pattern. No secrets are hardcoded: keys are resolved from `self.config`
        // (Keychain + Info.plist) and Gmail's token from the credential store.

        // One shared on-device recognizer powers both live transcription and the
        // wake-word detector (it phrase-matches over the same recognition stream).
        let recognizer: any SpeechRecognizing = speechRecognizer ?? LiveSpeechRecognitionService()
        self.speechRecognizer = recognizer

        // Compose presenter + real system messaging service. The presenter shows
        // the native MessageUI compose sheets from the key window's top view
        // controller; the service's `present` closure hops to the main actor to
        // drive it. The SAME instance backs both compose and inbox surfaces.
        let presenter = ComposePresenter()
        let messaging = AppEnvironment.makeMessagingService(presenter: presenter)
        let realCompose: any MessageComposeService = messageCompose ?? messaging
        let realInbox: any MessageInboxService = messageInbox ?? messaging
        self.messageCompose = realCompose
        self.messageInbox = realInbox

        // Prefer Apple's on-device Foundation Models (free, private, no key) when
        // available; otherwise fall back to the key-based Anthropic client.
        let realLLM: any LLMService
        if let llm {
            realLLM = llm
        } else if FoundationModelsLLMService.isAvailable {
            realLLM = FoundationModelsLLMService()
        } else {
            realLLM = RemoteLLMClient(keyProvider: APIKeyProvider(configKey: self.config.llmAPIKey))
        }
        self.llm = realLLM

        // Default info providers are FREE and need NO API key:
        //   weather -> Open-Meteo, stocks -> Yahoo Finance, news -> Google News RSS.
        let realWeather = weather ?? OpenMeteoWeatherService()
        self.weather = realWeather

        let realStocks = stocks ?? YahooStockService()
        self.stocks = realStocks

        let realNews = news ?? GoogleNewsRSSService()
        self.news = realNews

        let realEmail = email ?? GmailService(tokenProvider: { store.value(for: "SE_GMAIL_TOKEN") })
        self.email = realEmail

        let realContacts = contacts ?? LiveContactResolver()
        self.contacts = realContacts

        self.speechSynthesizer = speechSynthesizer ?? LiveTextToSpeechService()
        self.wakeWord = wakeWord ?? WakeWordDetector(
            recognizer: recognizer,
            triggerPhrase: AppEnvironment.defaultWakePhrase
        )
        self.gestures = gestures ?? AirPodInputService()
        self.chime = chime ?? LiveChimeService()

        // The default router depends on the resolved info/comms services above.
        self.toolRouter = toolRouter ?? AssistantToolRouter(
            llm: realLLM,
            weather: realWeather,
            stocks: realStocks,
            news: realNews,
            messageCompose: realCompose,
            messageInbox: realInbox,
            email: realEmail,
            contacts: realContacts
        )
    }

    /// Builds the real `SystemMessagingService`, wiring its `present` closure to
    /// the `ComposePresenter` on the main actor. Falls back to MessageUI's own
    /// platform-compat behavior where MessageUI is unavailable.
    @MainActor
    private static func makeMessagingService(presenter: ComposePresenter) -> any MessagingService {
        #if canImport(MessageUI)
        return SystemMessagingService { recipients, body in
            Task { @MainActor in presenter.presentMessage(recipients: recipients, body: body) }
        }
        #else
        return SystemMessagingService()
        #endif
    }

    /// Default wake phrase used to initialize the live wake-word detector.
    static let defaultWakePhrase = "Hey SmartEars"

    /// Builds the real weather service (WeatherKit on supported SDKs, with a live
    /// CoreLocation provider). Falls back to the WeatherKit service's own throwing
    /// behavior when location/entitlements are unavailable.
    private static func makeWeatherService() -> any WeatherService {
        #if canImport(WeatherKit)
        return WeatherKitWeatherService(currentLocationProvider: LiveLocationProvider.current)
        #else
        return StubWeatherService()
        #endif
    }

    /// Convenience flag for the UI: are we running entirely on mock services?
    public var isUsingMockServices: Bool {
        !CredentialSlot.allCases.contains { hasCredential(for: $0) }
    }

    /// Tracks which credential slots currently hold a key, so SwiftUI re-renders
    /// Settings when the user saves/clears one. The values themselves live only in
    /// the Keychain (`credentialStore`) — never in this map.
    @Published public private(set) var pendingCredentials: [CredentialSlot: Bool] = [:]

    public enum CredentialSlot: String, CaseIterable, Identifiable, Sendable {
        // Only the LLM (Ask-AI) and Gmail need credentials. Weather, stocks, and
        // news use free, key-free providers (Open-Meteo, Yahoo Finance, Google
        // News RSS), so they're intentionally absent here.
        case llm, gmail
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .llm: return "AI (Anthropic) API Key"
            case .gmail: return "Gmail Sign-in"
            }
        }
        /// Optional helper text shown under each field in Settings.
        public var hint: String {
            switch self {
            case .llm: return "Ask-AI runs free on-device on iPhone 15 Pro+ (iOS 26). Only older devices need a key — get one at console.anthropic.com."
            case .gmail: return "Connect Gmail to read & flag important email."
            }
        }
        /// The Info.plist / Keychain key this credential resolves to.
        public var infoPlistKey: String {
            switch self {
            case .llm: return "SE_LLM_API_KEY"
            case .gmail: return "SE_GMAIL_CLIENT_ID"
            }
        }
    }

    /// Returns whether a credential slot currently has a value resolved
    /// (from the Keychain, or an Info.plist placeholder at launch).
    public func hasCredential(for slot: CredentialSlot) -> Bool {
        credential(for: slot) != nil
    }

    /// Returns the resolved secret for a slot (Keychain first, then the launch
    /// config). Services/`ServiceFactory` read keys through this accessor.
    public func credential(for slot: CredentialSlot) -> String? {
        if let stored = credentialStore.value(for: slot.infoPlistKey) { return stored }
        switch slot {
        case .llm: return config.llmAPIKey
        case .gmail: return config.gmailClientID
        }
    }

    /// Securely persists an API key the user pasted in Settings to the Keychain.
    public func saveCredential(_ value: String, for slot: CredentialSlot) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if credentialStore.set(trimmed, for: slot.infoPlistKey) {
            pendingCredentials[slot] = true   // @Published -> Settings re-renders
        }
    }

    /// Removes a stored credential from the Keychain.
    public func clearCredential(for slot: CredentialSlot) {
        if credentialStore.delete(for: slot.infoPlistKey) {
            pendingCredentials[slot] = false
        }
    }
}

