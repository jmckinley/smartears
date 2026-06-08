import Foundation

// MARK: - LLMClient (Assistant AI layer)
//
// This file defines the chat/completion boundary for the assistant's language
// model, plus two implementations:
//
//  * `StubLLMClient`   — returns realistic canned responses so the app COMPILES
//                        AND RUNS WITH NO SECRETS PRESENT. Used by default.
//  * `RemoteLLMClient` — a skeleton URLSession-backed client for the real
//                        Anthropic Messages API. It reads its API key from a
//                        config/Keychain placeholder (NEVER hardcoded — see the
//                        TODO in `APIKeyProvider`). The request body example uses
//                        the latest Claude model id "claude-opus-4-8".
//
// Both conform to the shared `LLMService` protocol defined in Models.swift, so
// they are drop-in swappable via the ServiceFactory without changing call sites.
//
// NOTE: We intentionally keep a small, transport-agnostic `LLMChatClient`
// abstraction here (chat-message-shaped) in addition to satisfying the
// `LLMService` protocol. This mirrors how modern chat APIs (Anthropic, etc.)
// are message-oriented rather than single-prompt-oriented, while still
// presenting the simpler `complete`/`classifyIntent` surface to the rest of
// the app.

// MARK: - Chat Message Shape

/// Role of a single chat message handed to the LLM.
public enum LLMRole: String, Sendable, Codable {
    case system
    case user
    case assistant
}

/// One message in a chat-style LLM exchange.
public struct LLMMessage: Sendable, Codable, Equatable {
    public let role: LLMRole
    public let content: String
    public init(role: LLMRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// A chat/completion-shaped client. This is the richer surface the assistant
/// uses internally; `LLMService` conformance is layered on top of it.
public protocol LLMChatClient: Sendable {
    /// Send a chat-style exchange and receive the assistant's reply text.
    /// `system` is an optional system prompt applied ahead of `messages`.
    func chat(system: String?, messages: [LLMMessage]) async throws -> String
}

// MARK: - API Key Provider (no hardcoded secrets)

/// Resolves the LLM API key from configuration / Keychain.
///
/// IMPORTANT: There is NO secret in source. The key is resolved at runtime from
/// (in order) an injected `AppConfig` value, then a Keychain lookup placeholder.
/// If neither resolves, the caller should fall back to `StubLLMClient`.
public struct APIKeyProvider: Sendable {
    private let configKey: String?

    public init(configKey: String? = nil) {
        self.configKey = configKey
    }

    /// Returns the resolved API key, or `nil` if no credential is present.
    public func resolve() -> String? {
        // 1. Prefer an explicitly-injected config value (from AppConfig.load(),
        //    which itself reads Info.plist placeholders resolved from a
        //    gitignored xcconfig — never committed).
        if let configKey, !configKey.isEmpty { return configKey }

        // 2. TODO: Read from Keychain Services here, e.g.
        //    `return Keychain.shared.string(forKey: "SE_LLM_API_KEY")`.
        //    Intentionally NOT implemented to avoid shipping any secret-handling
        //    that could be mistaken for a hardcoded key. No key is hardcoded.
        return nil
    }
}

// MARK: - Stub LLM Client (default, no secrets)

/// A deterministic, offline LLM client returning realistic canned responses.
/// This lets the entire assistant pipeline run end-to-end with NO API key.
public struct StubLLMClient: LLMChatClient, LLMService {

    public init() {}

    // MARK: LLMChatClient

    public func chat(system: String?, messages: [LLMMessage]) async throws -> String {
        // Tiny artificial latency so callers exercise their async/loading paths.
        try? await Task.sleep(nanoseconds: 120_000_000) // ~0.12s
        let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""
        return Self.cannedReply(for: lastUser)
    }

    // MARK: LLMService

    public func complete(prompt: String, context: [String]) async throws -> String {
        var messages = context.map { LLMMessage(role: .user, content: $0) }
        messages.append(LLMMessage(role: .user, content: prompt))
        return try await chat(system: Self.systemPrompt, messages: messages)
    }

    public func classifyIntent(transcript: String) async throws -> AssistantIntent {
        // The stub mirrors the lightweight keyword classifier so the LLM-fallback
        // path is exercised offline. The real router still runs on-device rules
        // first; this is only invoked when those are ambiguous.
        try? await Task.sleep(nanoseconds: 80_000_000)
        return IntentClassifier.classify(transcript)
    }

    // MARK: Canned content

    static let systemPrompt = """
    You are SmartEars, an audio-first voice assistant heard through AirPods. \
    Replies are short, natural, and easy to listen to — one or two sentences, \
    no lists or markdown, since everything is spoken aloud.
    """

    /// Produces a plausible spoken-style reply keyed off simple cues in the
    /// utterance. Kept intentionally varied but deterministic.
    static func cannedReply(for utterance: String) -> String {
        let u = utterance.lowercased()
        switch true {
        case u.contains("hello"), u.contains("hi "), u == "hi", u.contains("hey"):
            return "Hey! I'm right here in your ears. What can I do for you?"
        case u.contains("thank"):
            return "Anytime. Just say the word if you need anything else."
        case u.contains("joke"):
            return "Why did the AirPods refuse to argue? They didn't want to lose their case."
        case u.contains("how are you"):
            return "Running smoothly and ready to help. How are you doing?"
        case u.contains("time"):
            return "I can't read the clock for you in this offline demo, but your phone's lock screen has it handy."
        case u.contains("remind"), u.contains("reminder"):
            return "I can't set reminders in this build yet, but that's on the roadmap."
        case u.isEmpty:
            return "I didn't quite catch that. Could you say it again?"
        default:
            return "Here's the short version: that's a great question, and in the live build I'd look it up for you. For now I'm running on canned responses so everything works without any keys."
        }
    }
}

// MARK: - Remote LLM Client (skeleton — real Anthropic Messages API)

/// Skeleton of the production LLM client backed by URLSession and the Anthropic
/// Messages API. This is a SKELETON: it wires up the request/response shape and
/// key resolution, but is only used when a real credential resolves. With no
/// key present, the ServiceFactory returns `StubLLMClient` instead.
///
/// The request body example below targets the latest Claude model id
/// `claude-opus-4-8`.
public struct RemoteLLMClient: LLMChatClient, LLMService {

    private let session: URLSession
    private let keyProvider: APIKeyProvider
    private let model: String
    private let endpoint: URL

    /// - Parameters:
    ///   - keyProvider: resolves the API key from config/Keychain (no hardcoding).
    ///   - model: Claude model id; defaults to the latest "claude-opus-4-8".
    ///   - session: injected for testing.
    public init(
        keyProvider: APIKeyProvider,
        model: String = "claude-opus-4-8",
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.keyProvider = keyProvider
        self.model = model
        self.session = session
        self.endpoint = endpoint
    }

    // MARK: LLMChatClient

    public func chat(system: String?, messages: [LLMMessage]) async throws -> String {
        // Resolve the key at call time. NEVER hardcoded — see APIKeyProvider.
        guard let apiKey = keyProvider.resolve(), !apiKey.isEmpty else {
            // Caller (ServiceFactory) should have used StubLLMClient when no key
            // is present; surface a typed error if we somehow got here.
            throw SmartEarsError.missingCredential("SE_LLM_API_KEY")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic auth + version headers. The key comes from the provider only.
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Example request body (Anthropic Messages API):
        //
        // {
        //   "model": "claude-opus-4-8",
        //   "max_tokens": 512,
        //   "system": "You are SmartEars...",
        //   "messages": [
        //     { "role": "user", "content": "What's the weather like?" }
        //   ]
        // }
        //
        // The Messages API does not accept a "system" role inside `messages`;
        // it's a top-level field. We split it out here accordingly.
        let body = MessagesRequest(
            model: model,
            maxTokens: 512,
            system: system,
            messages: messages
                .filter { $0.role != .system }
                .map { MessagesRequest.Message(role: $0.role.rawValue, content: $0.content) }
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw SmartEarsError.decoding("Failed to encode LLM request: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SmartEarsError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SmartEarsError.network("LLM HTTP \(code)")
        }

        do {
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            // Concatenate any text blocks in the response content.
            let text = decoded.content
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
            return text.isEmpty ? "I didn't get a usable reply that time." : text
        } catch {
            throw SmartEarsError.decoding("Failed to decode LLM response: \(error.localizedDescription)")
        }
    }

    // MARK: LLMService

    public func complete(prompt: String, context: [String]) async throws -> String {
        var messages = context.map { LLMMessage(role: .user, content: $0) }
        messages.append(LLMMessage(role: .user, content: prompt))
        return try await chat(system: StubLLMClient.systemPrompt, messages: messages)
    }

    public func classifyIntent(transcript: String) async throws -> AssistantIntent {
        // In production this would ask the model to emit a structured tool-call /
        // JSON intent. The skeleton runs on-device classification first and only
        // calls the model if needed. Here we keep the deterministic fallback so
        // behavior is well-defined; replace with a real structured-output call.
        let local = IntentClassifier.classify(transcript)
        if case .unknown = local {
            // TODO: issue a structured-output request asking the model to map the
            // utterance onto an AssistantIntent case and decode it here.
            return .conversational(prompt: transcript)
        }
        return local
    }
}

// MARK: - Anthropic Messages API wire types (skeleton)

/// Minimal request body for the Anthropic Messages API.
private struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

/// Minimal response body for the Anthropic Messages API.
private struct MessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    let content: [ContentBlock]
}
