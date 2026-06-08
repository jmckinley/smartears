import Foundation

// MARK: - AssistantToolRouter (Assistant AI layer)
//
// Two responsibilities live here:
//
//  1. `IntentClassifier` — a lightweight, on-device, keyword-first classifier
//     that turns a raw user utterance into an `AssistantIntent`. It runs first
//     (cheap, offline, private). When it returns `.unknown`, callers may ask the
//     LLM (`LLMService.classifyIntent`) for a best-effort fallback.
//
//  2. `AssistantToolRouter` — conforms to the shared `ToolRouting` protocol and
//     maps each `AssistantIntent` case onto concrete service calls (weather,
//     stocks, news, messaging, email, playback) and an LLM for conversational
//     turns. It produces a unified `AssistantResponse`, including building a
//     `PendingConfirmation` (yes / no / change readback) before any send.
//
// This file depends on the info/comms services ONLY through their protocols
// (WeatherService, StockService, NewsService, MessageComposeService,
// MessageInboxService, EmailService, ContactResolving) defined in Models.swift.
// It does NOT implement those services.
//
// Apple-platform honesty (mirrored from Models.swift):
//  * SMS/iMessage are COMPOSE-ONLY via MessageUI — the user must tap Send. The
//    router therefore produces a PendingConfirmation and the compose service
//    surfaces `SmartEarsError.userActionRequired`; we never auto-send.
//  * Apple Mail content is not programmatically readable; full inbound email is
//    only available via the Gmail API path behind `EmailService`.

// MARK: - Intent Classification

/// Cheap, deterministic, on-device intent classification from an utterance.
/// Keyword + simple-slot extraction first; the LLM is a fallback, not required.
public enum IntentClassifier {

    /// Classify a raw utterance into an `AssistantIntent`. Returns `.unknown`
    /// (carrying the transcript) when no rule matches confidently, so the caller
    /// can optionally consult the LLM.
    public static func classify(_ utterance: String) -> AssistantIntent {
        let raw = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.lowercased()
        guard !text.isEmpty else { return .unknown(transcript: raw) }

        // --- Playback / transport control -------------------------------------
        if let cmd = playbackCommand(in: text) {
            return .playbackControl(cmd)
        }

        // --- Wake word / trigger configuration --------------------------------
        if text.contains("wake word") || text.contains("wake phrase")
            || text.contains("change the trigger") || text.contains("call you") {
            let phrase = extractTrailing(after: ["wake word", "wake phrase", "call you"], in: raw)
            return .configureTrigger(phrase: phrase)
        }

        // --- Email (check before generic "send" so "email" wins) --------------
        if text.contains("email") || text.contains("e-mail") {
            if isReadIntent(text) {
                return .readEmail(filter: alertFilter(in: text))
            }
            let (recipient, subject, body) = parseEmailSlots(from: raw)
            return .composeEmail(recipient: recipient, subject: subject, body: body)
        }

        // --- Messaging / texting ----------------------------------------------
        if text.contains("text") || text.contains("message") || text.contains("imessage")
            || text.hasPrefix("send a ") || text.contains("send a text") {
            if isReadIntent(text) && (text.contains("message") || text.contains("text")) {
                return .readAlerts(filter: alertFilter(in: text))
            }
            let channel: MessageChannel = text.contains("whatsapp") ? .whatsapp : .sms
            let (recipient, body) = parseMessageSlots(from: raw)
            return .composeMessage(channel: channel, recipient: recipient, body: body)
        }

        // --- Alerts / "catch me up" -------------------------------------------
        if text.contains("catch me up") || text.contains("important")
            || text.contains("my alerts") || text.contains("anything new") {
            return .readAlerts(filter: alertFilter(in: text))
        }

        // --- Weather -----------------------------------------------------------
        if text.contains("weather") || text.contains("temperature")
            || text.contains("forecast") || text.contains("how hot") || text.contains("how cold") {
            let location = extractLocation(from: raw)
            return .weather(location: location)
        }

        // --- Stocks ------------------------------------------------------------
        if text.contains("stock") || text.contains("price of") || text.contains("ticker")
            || text.contains("how's") && hasTickerCue(text) || text.contains("share price") {
            if let symbol = extractSymbol(from: raw) {
                return .stock(symbol: symbol)
            }
        }

        // --- News --------------------------------------------------------------
        if text.contains("news") || text.contains("headlines") || text.contains("what's happening") {
            let topic = extractTopic(from: raw)
            return .news(topic: topic)
        }

        // Nothing matched — let the caller decide to consult the LLM or treat as
        // a conversational turn.
        return .unknown(transcript: raw)
    }

    // MARK: Slot helpers

    private static func isReadIntent(_ text: String) -> Bool {
        text.contains("read") || text.contains("check") || text.contains("any ")
            || text.contains("show me") || text.contains("latest") || text.contains("catch me up")
    }

    private static func alertFilter(in text: String) -> AlertFilter {
        if text.contains("important") || text.contains("urgent") { return .importantOnly }
        if text.contains("unread") || text.contains("new") { return .unread }
        return .all
    }

    private static func playbackCommand(in text: String) -> PlaybackCommand? {
        switch true {
        case text == "stop", text.contains("stop talking"), text.contains("be quiet"): return .stop
        case text.contains("never mind"), text.contains("cancel that"), text == "cancel": return .cancel
        case text.contains("pause"): return .pause
        case text.contains("resume"), text.contains("continue"), text.contains("keep going"): return .resume
        case text == "play": return .play
        case text.contains("repeat"), text.contains("say that again"), text.contains("what did you say"): return .repeatLast
        case text.contains("next"): return .next
        case text.contains("previous"), text.contains("go back"): return .previous
        case text.contains("louder"), text.contains("turn it up"), text.contains("volume up"): return .volumeUp
        case text.contains("quieter"), text.contains("turn it down"), text.contains("volume down"): return .volumeDown
        case text.contains("mute"): return .mute
        case text.contains("unmute"): return .unmute
        default: return nil
        }
    }

    private static func hasTickerCue(_ text: String) -> Bool {
        text.contains("doing") || text.contains("trading") || text.contains("up or down")
    }

    /// Extracts a likely location phrase after "in"/"for".
    private static func extractLocation(from raw: String) -> String? {
        for marker in [" in ", " for ", " at "] {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                let tail = raw[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
                if !tail.isEmpty { return tail }
            }
        }
        return nil // nil = current location
    }

    /// Extracts a topic for news after "about"/"on".
    private static func extractTopic(from raw: String) -> String? {
        for marker in [" about ", " on ", " regarding "] {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                let tail = raw[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
                if !tail.isEmpty { return tail }
            }
        }
        return nil
    }

    /// Extracts a stock symbol: an explicit ALL-CAPS ticker, or a known company name.
    private static func extractSymbol(from raw: String) -> String? {
        // Explicit uppercase ticker token (2–5 letters).
        let tokens = raw.split { !$0.isLetter }
        for token in tokens where (2...5).contains(token.count) && token.allSatisfy({ $0.isUppercase }) {
            return String(token)
        }
        // Common company-name -> ticker shortcuts.
        let lower = raw.lowercased()
        let map: [String: String] = [
            "apple": "AAPL", "tesla": "TSLA", "amazon": "AMZN", "google": "GOOGL",
            "alphabet": "GOOGL", "microsoft": "MSFT", "nvidia": "NVDA", "meta": "META",
            "netflix": "NFLX", "facebook": "META"
        ]
        for (name, symbol) in map where lower.contains(name) { return symbol }
        return nil
    }

    /// Returns text trailing one of the given markers (used for the wake phrase).
    private static func extractTrailing(after markers: [String], in raw: String) -> String? {
        for marker in markers {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                let tail = raw[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'?.!"))
                if !tail.isEmpty { return tail }
            }
        }
        return nil
    }

    /// Parse "(send a) text to <recipient>: <body>" / "...saying <body>".
    private static func parseMessageSlots(from raw: String) -> (recipient: String?, body: String?) {
        var recipient: String?
        var body: String?

        if let toRange = raw.range(of: " to ", options: .caseInsensitive) {
            var after = String(raw[toRange.upperBound...])
            // Body delimiters: ":" or "saying" or "that says".
            for delim in [":", " saying ", " that says ", " message ", " - "] {
                if let dr = after.range(of: delim, options: .caseInsensitive) {
                    body = after[dr.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    after = String(after[..<dr.lowerBound])
                    break
                }
            }
            recipient = after.trimmingCharacters(in: CharacterSet(charactersIn: " ,.\"'"))
            if recipient?.isEmpty == true { recipient = nil }
        }
        return (recipient, body)
    }

    /// Parse "(send an) email to <recipient> subject <s>: <body>".
    private static func parseEmailSlots(from raw: String) -> (recipient: String?, subject: String?, body: String?) {
        var recipient: String?
        var subject: String?
        var body: String?

        var working = raw
        if let toRange = working.range(of: " to ", options: .caseInsensitive) {
            working = String(working[toRange.upperBound...])
        } else {
            return (nil, nil, nil)
        }

        // Body after ":" or "saying".
        for delim in [":", " saying ", " that says "] {
            if let dr = working.range(of: delim, options: .caseInsensitive) {
                body = working[dr.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                working = String(working[..<dr.lowerBound])
                break
            }
        }
        // Subject after "subject" / "about".
        for delim in [" subject ", " about ", " re "] {
            if let sr = working.range(of: delim, options: .caseInsensitive) {
                subject = working[sr.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                working = String(working[..<sr.lowerBound])
                break
            }
        }
        recipient = working.trimmingCharacters(in: CharacterSet(charactersIn: " ,.\"'"))
        if recipient?.isEmpty == true { recipient = nil }
        return (recipient, subject, body)
    }
}

// MARK: - Tool Router

/// Maps a parsed `AssistantIntent` onto concrete service calls and returns a
/// unified `AssistantResponse`. Conforms to the shared `ToolRouting` protocol.
///
/// All collaborators are injected as protocols (Models.swift), so the same
/// router works against Mock services (no secrets) and real network services.
public struct AssistantToolRouter: ToolRouting {

    private let llm: LLMService
    private let weather: WeatherService
    private let stocks: StockService
    private let news: NewsService
    private let messageCompose: MessageComposeService
    private let messageInbox: MessageInboxService
    private let email: EmailService
    private let contacts: ContactResolving

    public init(
        llm: LLMService,
        weather: WeatherService,
        stocks: StockService,
        news: NewsService,
        messageCompose: MessageComposeService,
        messageInbox: MessageInboxService,
        email: EmailService,
        contacts: ContactResolving
    ) {
        self.llm = llm
        self.weather = weather
        self.stocks = stocks
        self.news = news
        self.messageCompose = messageCompose
        self.messageInbox = messageInbox
        self.email = email
        self.contacts = contacts
    }

    // MARK: ToolRouting

    /// Route an already-parsed intent. Non-throwing: every error path is turned
    /// into a graceful spoken response.
    public func route(_ intent: AssistantIntent) async -> AssistantResponse {
        await route(intent, context: [])
    }

    /// Context-aware routing: `context` is the rolling conversation window passed
    /// to the LLM for conversational coherence (multi-turn follow-ups).
    public func route(_ intent: AssistantIntent, context: [String]) async -> AssistantResponse {
        switch intent {
        case .conversational(let prompt):
            return await handleConversational(prompt, context: context)
        case .weather(let location):
            return await handleWeather(location)
        case .stock(let symbol):
            return await handleStock(symbol)
        case .news(let topic):
            return await handleNews(topic)
        case .readAlerts(let filter):
            return await handleReadAlerts(filter)
        case .composeMessage(let channel, let recipient, let body):
            return await handleComposeMessage(channel: channel, recipient: recipient, body: body)
        case .replyToAlert(_, let body):
            // Without the alert/contact lookup wired in this layer we acknowledge
            // and ask for confirmation details. The Comms layer fills in context.
            return AssistantResponse(
                spokenText: body == nil
                    ? "What would you like me to say in your reply?"
                    : "Okay. I'll get your reply ready to send.",
                followUpExpected: body == nil
            )
        case .composeEmail(let recipient, let subject, let body):
            return await handleComposeEmail(recipient: recipient, subject: subject, body: body)
        case .readEmail(let filter):
            return await handleReadEmail(filter)
        case .playbackControl(let command):
            return handlePlayback(command)
        case .configureTrigger(let phrase):
            return handleConfigureTrigger(phrase)
        case .unknown(let transcript):
            // Last resort: hand the raw transcript to the LLM for graceful recovery.
            return await handleConversational(transcript, context: context)
        }
    }

    /// Convenience: classify a raw utterance (on-device first, LLM fallback) and
    /// route it in one call. `context` is the rolling conversation window threaded
    /// through to the LLM for multi-turn coherence.
    public func handle(utterance: String, context: [String] = []) async -> AssistantResponse {
        var intent = IntentClassifier.classify(utterance)
        if case .unknown = intent {
            // On-device rules were ambiguous — try the LLM classifier, then route.
            if let llmIntent = try? await llm.classifyIntent(transcript: utterance) {
                intent = llmIntent
            } else {
                intent = .conversational(prompt: utterance)
            }
        }
        return await route(intent, context: context)
    }

    // MARK: - Handlers

    private func handleConversational(_ prompt: String, context: [String] = []) async -> AssistantResponse {
        do {
            let reply = try await llm.complete(prompt: prompt, context: context)
            return AssistantResponse(
                spokenText: reply,
                displayCard: DisplayCard(kind: .conversation, title: "SmartEars", body: reply),
                followUpExpected: true
            )
        } catch {
            return errorResponse("I had trouble thinking that through just now.", error)
        }
    }

    private func handleWeather(_ location: String?) async -> AssistantResponse {
        do {
            let w = try await weather.currentWeather(location: location)
            let spoken = String(
                format: "In %@ it's %.0f degrees and %@.",
                w.locationName, w.temperatureF, w.conditionDescription
            )
            return AssistantResponse(
                spokenText: spoken,
                displayCard: DisplayCard(
                    kind: .weather,
                    title: w.locationName,
                    subtitle: String(format: "%.0f°F", w.temperatureF),
                    body: w.conditionDescription
                ),
                followUpExpected: true
            )
        } catch {
            return errorResponse("I couldn't get the weather right now.", error)
        }
    }

    private func handleStock(_ symbol: String) async -> AssistantResponse {
        do {
            let q = try await stocks.quote(symbol: symbol)
            let direction = q.isUp ? "up" : "down"
            let spoken = String(
                format: "%@ is at %.2f %@, %@ %.2f percent today.",
                q.companyName ?? q.symbol, q.price, q.currency, direction, abs(q.changePercent)
            )
            return AssistantResponse(
                spokenText: spoken,
                displayCard: DisplayCard(
                    kind: .stock,
                    title: q.symbol,
                    subtitle: String(format: "%.2f %@", q.price, q.currency),
                    body: String(format: "%@ %.2f%%", direction, abs(q.changePercent))
                ),
                followUpExpected: true
            )
        } catch {
            return errorResponse("I couldn't pull that quote right now.", error)
        }
    }

    private func handleNews(_ topic: String?) async -> AssistantResponse {
        do {
            let items = try await news.headlines(topic: topic, limit: 3)
            guard !items.isEmpty else {
                return AssistantResponse(spokenText: "I didn't find any headlines just now.")
            }
            let lead = topic.map { "Here's the latest on \($0). " } ?? "Here are the top headlines. "
            let spoken = lead + items.map(\.headline).joined(separator: ". ") + "."
            return AssistantResponse(
                spokenText: spoken,
                displayCard: DisplayCard(
                    kind: .news,
                    title: topic ?? "Top Headlines",
                    body: items.map(\.headline).joined(separator: "\n")
                ),
                followUpExpected: true
            )
        } catch {
            return errorResponse("I couldn't reach the news right now.", error)
        }
    }

    private func handleReadAlerts(_ filter: AlertFilter) async -> AssistantResponse {
        do {
            let messages = try await messageInbox.recentMessages(filter: filter)
            guard !messages.isEmpty else {
                return AssistantResponse(spokenText: "You're all caught up. Nothing new to read.")
            }
            let spoken = messages.prefix(4).map { msg -> String in
                let snippet = msg.preview ?? msg.body ?? "no preview available"
                return "\(msg.senderName) says: \(snippet)"
            }.joined(separator: ". ") + "."
            return AssistantResponse(
                spokenText: spoken,
                displayCard: DisplayCard(
                    kind: .alert,
                    title: "Messages",
                    subtitle: "\(messages.count) item(s)",
                    body: spoken
                ),
                followUpExpected: true
            )
        } catch {
            return errorResponse("I couldn't read your messages right now.", error)
        }
    }

    private func handleReadEmail(_ filter: AlertFilter) async -> AssistantResponse {
        do {
            let emails = try await email.recentEmails(filter: filter)
            guard !emails.isEmpty else {
                return AssistantResponse(spokenText: "No new email to read right now.")
            }
            let spoken = emails.prefix(3).map { e -> String in
                "From \(e.from): \(e.subject)."
            }.joined(separator: " ")
            return AssistantResponse(
                spokenText: "Here's your email. " + spoken,
                displayCard: DisplayCard(
                    kind: .email,
                    title: "Inbox",
                    subtitle: "\(emails.count) item(s)",
                    body: spoken
                ),
                followUpExpected: true
            )
        } catch {
            return errorResponse("I couldn't reach your email right now.", error)
        }
    }

    private func handleComposeMessage(
        channel: MessageChannel,
        recipient: String?,
        body: String?
    ) async -> AssistantResponse {
        // Need a recipient and a body before we can offer to send.
        guard let recipient, !recipient.isEmpty else {
            return AssistantResponse(spokenText: "Who should I send that to?", followUpExpected: true)
        }
        guard let body, !body.isEmpty else {
            return AssistantResponse(
                spokenText: "What should the message to \(recipient) say?",
                followUpExpected: true
            )
        }

        // Resolve the spoken name to a concrete handle (best effort).
        let resolved = try? await contacts.resolve(name: recipient)
        let displayRecipient = resolved?.displayName ?? recipient

        // SMS/iMessage are compose-only — the user must tap Send via MessageUI.
        // We build a PendingConfirmation (yes / no / change) and let the voice
        // layer read it back before presenting the system compose sheet.
        let readback = "Sending a \(channel.rawValue) to \(displayRecipient): \"\(body)\". " +
                       "Say yes to send, no to cancel, or change to edit."
        return AssistantResponse(
            spokenText: readback,
            displayCard: DisplayCard(
                kind: .system,
                title: "Message to \(displayRecipient)",
                subtitle: channel.rawValue.uppercased(),
                body: body
            ),
            pendingConfirmation: PendingConfirmation(
                action: .sendMessage(channel: channel, recipient: displayRecipient, body: body),
                readbackText: readback
            )
        )
    }

    private func handleComposeEmail(
        recipient: String?,
        subject: String?,
        body: String?
    ) async -> AssistantResponse {
        guard let recipient, !recipient.isEmpty else {
            return AssistantResponse(spokenText: "Who should I email?", followUpExpected: true)
        }
        guard let body, !body.isEmpty else {
            return AssistantResponse(
                spokenText: "What should the email to \(recipient) say?",
                followUpExpected: true
            )
        }
        let resolved = try? await contacts.resolve(name: recipient)
        let displayRecipient = resolved?.emailAddress ?? resolved?.displayName ?? recipient
        let finalSubject = subject ?? "(no subject)"

        let readback = "Emailing \(displayRecipient), subject \"\(finalSubject)\": \"\(body)\". " +
                       "Say yes to send, no to cancel, or change to edit."
        return AssistantResponse(
            spokenText: readback,
            displayCard: DisplayCard(
                kind: .email,
                title: "Email to \(displayRecipient)",
                subtitle: finalSubject,
                body: body
            ),
            pendingConfirmation: PendingConfirmation(
                action: .sendEmail(recipient: displayRecipient, subject: finalSubject, body: body),
                readbackText: readback
            )
        )
    }

    private func handlePlayback(_ command: PlaybackCommand) -> AssistantResponse {
        // Playback control is acted on by the Voice layer; the router only
        // produces an acknowledging response. `cancel`/`stop` end any flow.
        let spoken: String
        switch command {
        case .stop, .cancel: spoken = "Okay, stopping."
        case .pause: spoken = "Paused."
        case .resume, .play: spoken = "Okay."
        case .repeatLast: spoken = "" // Voice layer replays the last utterance.
        case .next: spoken = "Next."
        case .previous: spoken = "Going back."
        case .volumeUp: spoken = "Turning it up."
        case .volumeDown: spoken = "Turning it down."
        case .mute: spoken = "Muted."
        case .unmute: spoken = "Unmuted."
        }
        return AssistantResponse(spokenText: spoken)
    }

    private func handleConfigureTrigger(_ phrase: String?) -> AssistantResponse {
        guard let phrase, !phrase.isEmpty else {
            return AssistantResponse(
                spokenText: "What would you like my new wake word to be?",
                followUpExpected: true
            )
        }
        // The Voice layer's WakeWordEngine.setWakePhrase performs the change.
        return AssistantResponse(
            spokenText: "Got it. I'll answer to \"\(phrase)\" from now on.",
            displayCard: DisplayCard(kind: .system, title: "Wake word", body: phrase)
        )
    }

    // MARK: - Helpers

    private func errorResponse(_ friendly: String, _ error: Error) -> AssistantResponse {
        let detail = (error as? SmartEarsError)?.errorDescription ?? error.localizedDescription
        return AssistantResponse(
            spokenText: friendly,
            displayCard: DisplayCard(kind: .system, title: "Something went wrong", body: detail)
        )
    }
}
