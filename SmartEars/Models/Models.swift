import Foundation

// MARK: - SmartEars Shared Models (single source of truth)
//
// This file defines every cross-module type used by SmartEars. Feature
// implementers MUST import these types and MUST NOT redefine them. Service
// boundaries are protocol-oriented so that real/network implementations can be
// swapped for the bundled mock implementations without changing call sites.
//
// IMPORTANT Apple-platform reality checks baked into this design:
//  * iOS apps CANNOT silently read the system Messages (SMS/iMessage) database,
//    nor can they read arbitrary Mail.app content. There is no public API.
//    -> Outgoing SMS/iMessage is done ONLY via MessageUI's MFMessageComposeViewController
//       (user must tap Send; we cannot auto-send).
//    -> "Important text" alerting is therefore sourced from things we ARE allowed
//       to see: UNUserNotificationCenter content the user routes to us, or a
//       Notification Service / Communication Notifications entitlement, or a
//       user-driven share. We model an inbound abstraction (InboundMessageSource)
//       and are honest that the SMS body generally is not readable without user action.
//  * Third-party email (Gmail) is read/sent via the Gmail REST API with OAuth.
//    Apple Mail content is NOT programmatically readable; composing a mail is via
//    MessageUI's MFMailComposeViewController (user taps Send).
//  * All network providers (LLM, weather, stocks, news, Gmail) sit behind the
//    protocols below and ship with Mock* implementations returning realistic
//    sample data so the app COMPILES AND RUNS WITH NO SECRETS PRESENT.

// MARK: - Core Identifiers & Time

public typealias SmartEarsID = UUID

/// A monotonically-captured timestamp wrapper to keep call sites explicit.
public struct Timestamped<Value: Sendable>: Sendable {
    public let value: Value
    public let capturedAt: Date
    public init(_ value: Value, capturedAt: Date = Date()) {
        self.value = value
        self.capturedAt = capturedAt
    }
}

// MARK: - Assistant Intent Model

/// The set of intents the on-device/router layer can recognize from a voice
/// utterance (or a tapped quick-action). The `ToolRouter` maps each case to one
/// or more service calls. Associated values carry already-parsed slots.
public enum AssistantIntent: Sendable, Equatable {
    /// Free-form conversational turn handed to the LLM (default fallback).
    case conversational(prompt: String)

    /// "What's the weather in Denver" / "weather" (nil = current location).
    case weather(location: String?)

    /// "How's AAPL doing" / "price of Tesla".
    case stock(symbol: String)

    /// "What's the news" / "breaking news about <topic>".
    case news(topic: String?)

    /// "Read my important messages" / "catch me up".
    case readAlerts(filter: AlertFilter)

    /// "Send a text to <contact>: <body>" — opens MessageUI compose (user sends).
    case composeMessage(channel: MessageChannel, recipient: String?, body: String?)

    /// "Reply to <sender>" referencing an existing alert.
    case replyToAlert(alertID: SmartEarsID, body: String?)

    /// "Send an email to <addr> subject <s>: <body>" — Gmail API or MailCompose.
    case composeEmail(recipient: String?, subject: String?, body: String?)

    /// "Read my latest email" / "any important email".
    case readEmail(filter: AlertFilter)

    /// Control of audio output / TTS ("louder", "stop", "repeat that").
    case playbackControl(PlaybackCommand)

    /// Change the wake word or other trigger settings by voice.
    case configureTrigger(phrase: String?)

    /// Something we could not confidently classify; carries raw transcript so the
    /// LLM can attempt a graceful recovery ("Sorry, did you mean...").
    case unknown(transcript: String)
}

/// Coarse filter applied when surfacing alerts/emails.
public enum AlertFilter: String, Sendable, Codable, CaseIterable {
    case importantOnly
    case unread
    case all
}

/// Audio/TTS transport commands. Mapped from both voice and AirPod gestures.
public enum PlaybackCommand: String, Sendable, Codable, CaseIterable {
    case play, pause, resume, stop, repeatLast, next, previous
    case volumeUp, volumeDown, mute, unmute
    case cancel  // abort current multi-step flow ("never mind")
}

// MARK: - Assistant Response

/// Unified response object the assistant produces for any turn. The voice layer
/// speaks `spokenText`; the optional `displayCard` drives the minimal SwiftUI
/// surface (history/now-playing). `followUpExpected` keeps the mic open for a
/// contextual follow-up without re-triggering the wake word (Meta-style).
public struct AssistantResponse: Sendable, Identifiable {
    public let id: SmartEarsID
    public let spokenText: String
    public let displayCard: DisplayCard?
    public let followUpExpected: Bool
    /// If non-nil, the UI/voice layer should ask the user to confirm before the
    /// associated side effect (e.g. sending) is performed.
    public let pendingConfirmation: PendingConfirmation?
    public let createdAt: Date

    public init(
        id: SmartEarsID = UUID(),
        spokenText: String,
        displayCard: DisplayCard? = nil,
        followUpExpected: Bool = false,
        pendingConfirmation: PendingConfirmation? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spokenText = spokenText
        self.displayCard = displayCard
        self.followUpExpected = followUpExpected
        self.pendingConfirmation = pendingConfirmation
        self.createdAt = createdAt
    }
}

/// A confirmable side effect ("Ready to send? Say yes / no / change").
public struct PendingConfirmation: Sendable {
    public enum Action: Sendable {
        case sendMessage(channel: MessageChannel, recipient: String, body: String)
        case sendEmail(recipient: String, subject: String, body: String)
    }
    public let action: Action
    public let readbackText: String
    public init(action: Action, readbackText: String) {
        self.action = action
        self.readbackText = readbackText
    }
}

/// Lightweight content card for the optional on-screen surface. Voice remains
/// primary; this is for history review / glanceable state only.
public struct DisplayCard: Sendable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case conversation, weather, stock, news, alert, email, system
    }
    public let id: SmartEarsID
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let body: String?
    public init(
        id: SmartEarsID = UUID(),
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        body: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

// MARK: - Messaging & Email Domain

/// Channel a message is sent through. iMessage/SMS are compose-only (user taps
/// Send via MessageUI); WhatsApp/other are best-effort via URL schemes/Shortcuts.
public enum MessageChannel: String, Sendable, Codable, CaseIterable {
    case sms          // MFMessageComposeViewController (SMS/iMessage)
    case email        // Gmail API or MFMailComposeViewController
    case whatsapp     // url scheme / Shortcuts (best effort)
    case other
}

/// Where an inbound message summary originated. We are explicit that the raw
/// SMS body is generally NOT readable by a third-party app; most inbound items
/// arrive through notification content the user routes to us or via Gmail API.
public enum InboundMessageSource: String, Sendable, Codable {
    case gmailAPI            // full content available (OAuth scope granted)
    case userNotification    // limited content from UNNotification we receive
    case manualShare         // user shared content into the app
    case simulated           // mock/sample data
}

/// Importance scoring used by the alerting engine.
public enum Importance: Int, Sendable, Codable, Comparable, CaseIterable {
    case low = 0, normal = 1, high = 2, urgent = 3
    public static func < (lhs: Importance, rhs: Importance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A summarized inbound text/chat message (NOT a full Messages DB record — see
/// file header). `body` may be nil when only metadata is available.
public struct MessageSummary: Sendable, Identifiable, Codable {
    public let id: SmartEarsID
    public let channel: MessageChannel
    public let source: InboundMessageSource
    public let senderName: String
    public let senderHandle: String?      // phone/handle if known
    public let preview: String?           // short snippet for spoken summary
    public let body: String?              // full body when available (e.g. Gmail)
    public let importance: Importance
    public let receivedAt: Date
    public let isRead: Bool

    public init(
        id: SmartEarsID = UUID(),
        channel: MessageChannel,
        source: InboundMessageSource,
        senderName: String,
        senderHandle: String? = nil,
        preview: String? = nil,
        body: String? = nil,
        importance: Importance = .normal,
        receivedAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.channel = channel
        self.source = source
        self.senderName = senderName
        self.senderHandle = senderHandle
        self.preview = preview
        self.body = body
        self.importance = importance
        self.receivedAt = receivedAt
        self.isRead = isRead
    }
}

/// A summarized email. Full `body` is only reliably available via the Gmail API
/// (the sole third-party path with inbound content). Apple Mail content is NOT
/// programmatically readable.
public struct EmailSummary: Sendable, Identifiable, Codable {
    public let id: SmartEarsID
    public let source: InboundMessageSource
    public let from: String
    public let fromAddress: String?
    public let subject: String
    public let snippet: String?
    public let body: String?
    public let importance: Importance
    public let receivedAt: Date
    public let isRead: Bool

    public init(
        id: SmartEarsID = UUID(),
        source: InboundMessageSource = .gmailAPI,
        from: String,
        fromAddress: String? = nil,
        subject: String,
        snippet: String? = nil,
        body: String? = nil,
        importance: Importance = .normal,
        receivedAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.source = source
        self.from = from
        self.fromAddress = fromAddress
        self.subject = subject
        self.snippet = snippet
        self.body = body
        self.importance = importance
        self.receivedAt = receivedAt
        self.isRead = isRead
    }
}

// MARK: - Information Domain (Weather / Stocks / News)

/// A point-in-time weather reading for spoken summary.
public struct WeatherSnapshot: Sendable, Identifiable, Codable {
    public let id: SmartEarsID
    public let locationName: String
    public let temperatureC: Double
    public let conditionDescription: String
    public let highC: Double?
    public let lowC: Double?
    public let humidityPercent: Int?
    public let windKph: Double?
    public let capturedAt: Date

    public init(
        id: SmartEarsID = UUID(),
        locationName: String,
        temperatureC: Double,
        conditionDescription: String,
        highC: Double? = nil,
        lowC: Double? = nil,
        humidityPercent: Int? = nil,
        windKph: Double? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.locationName = locationName
        self.temperatureC = temperatureC
        self.conditionDescription = conditionDescription
        self.highC = highC
        self.lowC = lowC
        self.humidityPercent = humidityPercent
        self.windKph = windKph
        self.capturedAt = capturedAt
    }

    /// Convenience for spoken output in Fahrenheit.
    public var temperatureF: Double { temperatureC * 9 / 5 + 32 }
}

/// A single stock/ticker quote for spoken summary.
public struct StockQuote: Sendable, Identifiable, Codable {
    public var id: String { symbol }
    public let symbol: String
    public let companyName: String?
    public let price: Double
    public let currency: String
    public let changeAbsolute: Double
    public let changePercent: Double
    public let capturedAt: Date

    public init(
        symbol: String,
        companyName: String? = nil,
        price: Double,
        currency: String = "USD",
        changeAbsolute: Double,
        changePercent: Double,
        capturedAt: Date = Date()
    ) {
        self.symbol = symbol
        self.companyName = companyName
        self.price = price
        self.currency = currency
        self.changeAbsolute = changeAbsolute
        self.changePercent = changePercent
        self.capturedAt = capturedAt
    }

    public var isUp: Bool { changeAbsolute >= 0 }
}

/// A single news headline for spoken summary.
public struct NewsHeadline: Sendable, Identifiable, Codable {
    public let id: SmartEarsID
    public let headline: String
    public let source: String?
    public let summary: String?
    public let url: URL?
    public let publishedAt: Date

    public init(
        id: SmartEarsID = UUID(),
        headline: String,
        source: String? = nil,
        summary: String? = nil,
        url: URL? = nil,
        publishedAt: Date = Date()
    ) {
        self.id = id
        self.headline = headline
        self.source = source
        self.summary = summary
        self.url = url
        self.publishedAt = publishedAt
    }
}

// MARK: - Alerting Domain

/// What kind of inbound item produced an alert.
public enum AlertCategory: String, Sendable, Codable, CaseIterable {
    case message, email, system
}

/// A surfaced alert: an audio chime plus a spoken summary. Created by the
/// Alerting engine from `MessageSummary`/`EmailSummary` that pass the trigger.
public struct AlertItem: Sendable, Identifiable, Codable {
    public let id: SmartEarsID
    public let category: AlertCategory
    public let title: String
    public let spokenSummary: String
    public let importance: Importance
    public let sourceMessageID: SmartEarsID?
    public let createdAt: Date
    public var acknowledged: Bool

    public init(
        id: SmartEarsID = UUID(),
        category: AlertCategory,
        title: String,
        spokenSummary: String,
        importance: Importance,
        sourceMessageID: SmartEarsID? = nil,
        createdAt: Date = Date(),
        acknowledged: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.spokenSummary = spokenSummary
        self.importance = importance
        self.sourceMessageID = sourceMessageID
        self.createdAt = createdAt
        self.acknowledged = acknowledged
    }
}

/// User-configurable rules controlling when an inbound item becomes an audible
/// alert. Persisted in user defaults / store.
public struct TriggerConfig: Sendable, Codable, Equatable {
    /// Minimum importance that fires an audible alert.
    public var minimumImportance: Importance
    /// VIP sender names/handles that always alert regardless of importance.
    public var vipSenders: [String]
    /// Keywords that escalate an item to `urgent`.
    public var urgentKeywords: [String]
    /// Whether to read the full body aloud or just the preview.
    public var readFullBody: Bool
    /// Do-not-disturb window start hour (24h), nil = disabled.
    public var quietHoursStart: Int?
    public var quietHoursEnd: Int?

    public init(
        minimumImportance: Importance = .high,
        vipSenders: [String] = [],
        urgentKeywords: [String] = ["urgent", "asap", "emergency", "911"],
        readFullBody: Bool = false,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil
    ) {
        self.minimumImportance = minimumImportance
        self.vipSenders = vipSenders
        self.urgentKeywords = urgentKeywords
        self.readFullBody = readFullBody
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }

    public static let `default` = TriggerConfig()
}

// MARK: - Voice & Gesture Domain

/// The state machine for a hands-free voice turn (Meta/Gemini-style):
/// idle -> waking (chime) -> listening -> thinking -> speaking ->
/// awaitingFollowUp (mic stays open briefly without re-triggering wake word).
public enum VoiceSessionState: String, Sendable, Codable, Equatable {
    case idle
    case waking
    case listening
    case thinking
    case speaking
    case awaitingFollowUp
}

/// A finalized (or partial) speech-to-text result.
public struct Transcription: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Float
    public let capturedAt: Date

    public init(
        text: String,
        isFinal: Bool,
        confidence: Float = 1.0,
        capturedAt: Date = Date()
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.capturedAt = capturedAt
    }
}

/// AirPod-derived input. Raw stem-press events are NOT exposed by iOS; these are
/// reconstructed realistically from MPRemoteCommandCenter (transport), the audio
/// route/port change notifications (in-ear/removed), and CMHeadphoneMotionManager
/// (head nod/shake). `confidence` matters for probabilistic head gestures.
public enum AirPodGesture: Sendable, Equatable {
    case singlePress     // MPRemoteCommandCenter play/pause toggle
    case doublePress     // next track
    case triplePress     // previous track
    case earBudInserted  // route change -> bud placed in ear
    case earBudRemoved   // route change -> auto-pause
    case headNodYes      // CMHeadphoneMotionManager (supported AirPods)
    case headShakeNo     // CMHeadphoneMotionManager (supported AirPods)
}

/// A gesture event with provenance confidence (1.0 for deterministic transport
/// events, <1.0 for probabilistic head-motion classification).
public struct GestureEvent: Sendable, Equatable {
    public let gesture: AirPodGesture
    public let confidence: Float
    public let occurredAt: Date

    public init(gesture: AirPodGesture, confidence: Float = 1.0, occurredAt: Date = Date()) {
        self.gesture = gesture
        self.confidence = confidence
        self.occurredAt = occurredAt
    }
}

// MARK: - Errors

/// Unified error surface. `userActionRequired` honestly models the fact that
/// SMS/iMessage and Apple Mail sends REQUIRE the user to tap Send in a system
/// compose sheet — the app can never auto-send those channels.
public enum SmartEarsError: Error, Sendable, Equatable {
    /// The requested operation needs the user to complete a system UI step
    /// (e.g. tap Send in MFMessageComposeViewController / MFMailComposeViewController).
    case userActionRequired(String)
    /// A required permission (mic, speech, contacts, location, motion) was denied.
    case permissionDenied(String)
    /// A credential needed for a real provider is missing — caller should fall
    /// back to the Mock implementation. Never thrown when mocks are in use.
    case missingCredential(String)
    /// Network/transport failure talking to a provider.
    case network(String)
    /// Provider returned a payload we could not decode.
    case decoding(String)
    /// The intent could not be fulfilled (unsupported on this device, etc.).
    case unsupported(String)
    /// Catch-all with a human-readable message.
    case other(String)
}

extension SmartEarsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .userActionRequired(let m): return m
        case .permissionDenied(let m): return "Permission denied: \(m)"
        case .missingCredential(let m): return "Missing credential: \(m)"
        case .network(let m): return "Network error: \(m)"
        case .decoding(let m): return "Decoding error: \(m)"
        case .unsupported(let m): return "Unsupported: \(m)"
        case .other(let m): return m
        }
    }
}

// MARK: - App Configuration

/// Resolved app configuration. Credentials are read from Info.plist placeholders
/// (which are themselves resolved from a gitignored xcconfig) and/or Keychain.
/// When a credential is absent the corresponding `ServiceFactory` returns a Mock.
/// NO secrets are ever stored in source.
public struct AppConfig: Sendable {
    public let llmAPIKey: String?
    public let weatherAPIKey: String?
    public let stocksAPIKey: String?
    public let newsAPIKey: String?
    public let gmailClientID: String?

    public init(
        llmAPIKey: String? = nil,
        weatherAPIKey: String? = nil,
        stocksAPIKey: String? = nil,
        newsAPIKey: String? = nil,
        gmailClientID: String? = nil
    ) {
        self.llmAPIKey = llmAPIKey
        self.weatherAPIKey = weatherAPIKey
        self.stocksAPIKey = stocksAPIKey
        self.newsAPIKey = newsAPIKey
        self.gmailClientID = gmailClientID
    }

    public func hasCredential(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return true
    }

    /// Loads configuration from the main bundle's Info.plist placeholder keys.
    /// Empty/placeholder values (e.g. an unresolved "$(...)" token) are treated
    /// as absent so the app cleanly falls back to Mock services with no secrets.
    public static func load(bundle: Bundle = .main) -> AppConfig {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Treat empty or unresolved "$(...)" tokens as "no credential".
            if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
            return trimmed
        }
        return AppConfig(
            llmAPIKey: value("SE_LLM_API_KEY"),
            weatherAPIKey: value("SE_WEATHER_API_KEY"),
            stocksAPIKey: value("SE_STOCKS_API_KEY"),
            newsAPIKey: value("SE_NEWS_API_KEY"),
            gmailClientID: value("SE_GMAIL_CLIENT_ID")
        )
    }
}

// MARK: - Service Protocols (provider boundaries)
//
// Every external provider lives behind one of these protocols. Each ships with a
// Mock* implementation (in the relevant module's Mocks/ folder) returning
// realistic sample data so the app compiles and runs with NO secrets present.

/// Large-language-model provider used for conversational turns and intent
/// classification fallback. Real impl: HTTP (URLSession). Mock: canned replies.
public protocol LLMService: Sendable {
    /// Free-form conversational completion.
    func complete(prompt: String, context: [String]) async throws -> String
    /// Best-effort intent classification when on-device rules are ambiguous.
    func classifyIntent(transcript: String) async throws -> AssistantIntent
}

/// Weather provider. Real impl: HTTP. Mock: sample snapshot.
public protocol WeatherService: Sendable {
    func currentWeather(location: String?) async throws -> WeatherSnapshot
}

/// Stock-quote provider. Real impl: HTTP. Mock: sample quotes.
public protocol StockService: Sendable {
    func quote(symbol: String) async throws -> StockQuote
}

/// News provider. Real impl: HTTP. Mock: sample headlines.
public protocol NewsService: Sendable {
    func headlines(topic: String?, limit: Int) async throws -> [NewsHeadline]
}

/// Outbound message composition. SMS/iMessage are COMPOSE-ONLY via MessageUI:
/// implementations should surface `SmartEarsError.userActionRequired` because
/// the user must tap Send — there is no public auto-send API.
public protocol MessageComposeService: Sendable {
    func compose(channel: MessageChannel, recipient: String?, body: String?) async throws
}

/// Inbound message visibility. Honestly limited: raw SMS bodies are generally
/// NOT readable; items come from notifications the user routes to us, Gmail, or
/// simulated samples (see `InboundMessageSource`).
public protocol MessageInboxService: Sendable {
    func recentMessages(filter: AlertFilter) async throws -> [MessageSummary]
}

/// Email provider. Gmail-backed real impl (REST + OAuth) is the ONLY third-party
/// path with full inbound bodies. Apple Mail content is not readable; composing
/// Apple Mail is via MFMailComposeViewController (user taps Send).
public protocol EmailService: Sendable {
    func recentEmails(filter: AlertFilter) async throws -> [EmailSummary]
    /// May throw `userActionRequired` for the MailCompose (user-tap) path.
    func sendEmail(recipient: String, subject: String, body: String) async throws
}

/// Resolves a spoken name ("text Mom") to a concrete recipient handle via the
/// Contacts framework. Real impl: CNContactStore. Mock: sample contacts.
public protocol ContactResolving: Sendable {
    func resolve(name: String) async throws -> ResolvedContact?
}

/// A contact resolved from a spoken name.
public struct ResolvedContact: Sendable, Equatable, Codable {
    public let displayName: String
    public let phoneNumber: String?
    public let emailAddress: String?
    public init(displayName: String, phoneNumber: String? = nil, emailAddress: String? = nil) {
        self.displayName = displayName
        self.phoneNumber = phoneNumber
        self.emailAddress = emailAddress
    }
}

/// Speech-to-text. Real impl: SFSpeechRecognizer with stop-on-silence + a
/// max-utterance cap. Streams partial then final `Transcription` values.
public protocol SpeechRecognizing: Sendable {
    /// Streams transcriptions for one utterance, ending on silence or the cap.
    func transcribe() -> AsyncThrowingStream<Transcription, Error>
}

/// Text-to-speech — the PRIMARY output surface. Real impl: AVSpeechSynthesizer.
public protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String) async
    func stop() async
}

/// Wake-word detection. Real impl: SFSpeechRecognizer phrase-matching or a
/// bundled keyword-spotting model. NOTE: iOS does not support fully-custom,
/// always-on, on-device keyword models for third parties the way first-party
/// "Hey Siri" does — this is honestly a phrase-match approximation.
public protocol WakeWordEngine: Sendable {
    /// Emits when the configured wake phrase is detected.
    func wakeEvents() -> AsyncStream<Date>
    /// Updates the phrase to listen for ("Hey SmartEars", etc.).
    func setWakePhrase(_ phrase: String)
}

/// AirPod gesture source. Emits `GestureEvent`s reconstructed from the realistic
/// inputs documented on `AirPodGesture` (transport / route-change / head-motion).
public protocol GestureService: Sendable {
    func gestureEvents() -> AsyncStream<GestureEvent>
}

/// Audio playback chimes (wake sound + importance-scaled alert chime).
public protocol ChimeService: Sendable {
    func playWakeChime() async
    func playAlertChime(importance: Importance) async
}

/// Maps a parsed `AssistantIntent` to concrete service calls, producing an
/// `AssistantResponse`. The concrete `ToolRouter` conforms to this.
public protocol ToolRouting: Sendable {
    func route(_ intent: AssistantIntent) async -> AssistantResponse
}
