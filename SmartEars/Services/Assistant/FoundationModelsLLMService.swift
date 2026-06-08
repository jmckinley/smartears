import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - FoundationModelsLLMService (free, on-device, NO API key)
//
// Uses Apple Intelligence's on-device language model via the FoundationModels
// framework (iOS 26+, Apple-Intelligence-capable devices). It is free, private
// (runs on device), and needs no key — the ideal default for "ask the AI".
//
// Availability is gated at runtime: on unsupported OS/devices `isAvailable` is
// false and AppEnvironment falls back to the key-based RemoteLLMClient.

public struct FoundationModelsLLMService: LLMService {

    public init() {}

    /// Whether the on-device model can be used right now (OS + device + enabled).
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    private static let instructions =
        "You are SmartEars, a friendly voice assistant heard through the user's AirPods. " +
        "Answer in a concise, natural, spoken style — a sentence or two, no markdown or lists."

    public func complete(prompt: String, context: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw SmartEarsError.unsupported("On-device AI isn't available on this device.")
            }
            let session = LanguageModelSession(instructions: Self.instructions)
            // Fold a little recent context into the prompt for coherence.
            let recent = context.suffix(6).joined(separator: "\n")
            let input = recent.isEmpty ? prompt : "\(recent)\n\(prompt)"
            do {
                let response = try await session.respond(to: input)
                return response.content
            } catch {
                throw SmartEarsError.other("On-device AI couldn't answer that: \(error.localizedDescription)")
            }
        }
        #endif
        throw SmartEarsError.unsupported("On-device AI requires iOS 26 or later.")
    }

    public func classifyIntent(transcript: String) async throws -> AssistantIntent {
        // Fast, deterministic keyword routing — no model round-trip needed.
        let lower = transcript.lowercased()
        if lower.contains("weather") || lower.contains("forecast") || lower.contains("temperature") {
            return .weather(location: nil)
        }
        if lower.contains("news") || lower.contains("headline") || lower.contains("happening") {
            return .news(topic: nil)
        }
        if lower.contains("stock") || lower.contains("share price") || lower.contains("ticker") {
            return .stock(symbol: "AAPL")
        }
        return .conversational(prompt: transcript)
    }
}
