import Foundation
import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif

// MARK: - MessagingService (COMMS layer)
//
// HONEST APPLE-PLATFORM REALITY CHECK (read me):
//  * iOS does NOT let third-party apps silently read the Messages (SMS/iMessage)
//    database. There is NO public API for inbound SMS/iMessage content. Anything
//    we "read" must arrive through a channel the user explicitly grants us —
//    notification content we are entitled to (UNNotificationServiceExtension /
//    Communication Notifications), a user-driven share, or simulated samples.
//    -> See `InboundMessageSource` in Models.swift for the provenance model.
//  * Outbound SMS/iMessage is COMPOSE-ONLY via MFMessageComposeViewController.
//    We pre-fill recipient + body, but the USER must tap Send. We can never
//    auto-send. This is modeled as `SmartEarsError.userActionRequired`.
//
// This file provides:
//  * `MessagingService` — a focused protocol for composing an outbound message
//    and for the (deliberately limited) inbound-visibility story.
//  * `SystemMessagingService` — the real impl, presenting MFMessageComposeViewController.
//  * `MessageComposeView` — a UIViewControllerRepresentable SwiftUI wrapper.
//  * `StubMessagingService` — a no-network mock returning realistic sample data,
//    so the app compiles and runs with no entitlements/secrets present.

/// Result of presenting a system message-compose sheet.
public enum MessageComposeResult: Sendable, Equatable {
    case sent          // user tapped Send (MessageUI reported .sent)
    case cancelled     // user dismissed without sending
    case failed(String)
}

/// Focused COMMS-layer messaging protocol. Conforms to the shared
/// `MessageComposeService` (Models.swift) for the compose-only side, and adds
/// the honestly-limited inbound visibility surface.
///
/// NOTE: `compose(...)` throws `SmartEarsError.userActionRequired` because the
/// user must tap Send in the system sheet — there is no auto-send API.
public protocol MessagingService: MessageComposeService, MessageInboxService {
    /// Whether this device can present a message-compose sheet at all
    /// (e.g. a device with no SMS capability returns false).
    var canSendMessages: Bool { get }
}

#if canImport(UIKit) && canImport(MessageUI)

// MARK: - SwiftUI wrapper for MFMessageComposeViewController

/// A SwiftUI wrapper around `MFMessageComposeViewController`. Present this from a
/// SwiftUI surface (e.g. `.sheet`) to let the user send an SMS/iMessage. The user
/// MUST tap Send — we only pre-fill recipients + body.
public struct MessageComposeView: UIViewControllerRepresentable {
    public let recipients: [String]
    public let body: String?
    public let onFinish: (MessageComposeResult) -> Void

    public init(
        recipients: [String],
        body: String? = nil,
        onFinish: @escaping (MessageComposeResult) -> Void
    ) {
        self.recipients = recipients
        self.body = body
        self.onFinish = onFinish
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    public func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        if !recipients.isEmpty { controller.recipients = recipients }
        if let body { controller.body = body }
        return controller
    }

    public func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {
        // No dynamic updates needed; the compose sheet is configured once.
    }

    // The Coordinator is main-actor-isolated because UIKit drives its delegate
    // callbacks on the main thread. `@preconcurrency` quiets the cross-isolation
    // warning for the (nonisolated) UIKit delegate protocol.
    @MainActor
    public final class Coordinator: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
        private let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }

        // NOTE: UIKit's delegate hands back `MessageUI.MessageComposeResult`,
        // which shares a name with our own `MessageComposeResult`. We fully
        // qualify the UIKit type to disambiguate.
        public func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageUI.MessageComposeResult
        ) {
            let mapped: MessageComposeResult
            switch result {
            case .sent: mapped = .sent
            case .cancelled: mapped = .cancelled
            case .failed: mapped = .failed("MessageUI reported a send failure.")
            @unknown default: mapped = .failed("Unknown MessageUI result.")
            }
            controller.dismiss(animated: true) { [onFinish] in onFinish(mapped) }
        }
    }
}

// MARK: - Real messaging service

/// Real messaging service. Composing presents `MFMessageComposeViewController`;
/// the caller is responsible for actually presenting `MessageComposeView` from a
/// SwiftUI surface. This service models the contract honestly: composing always
/// ends in `userActionRequired` because we cannot auto-send.
@MainActor
public final class SystemMessagingService: MessagingService {
    /// A presenter closure the app wires up to show `MessageComposeView`.
    /// When nil, `compose` reports `userActionRequired` describing what the user
    /// needs to do. This keeps the service usable in headless/voice-only flows.
    public var present: ((_ recipients: [String], _ body: String?) -> Void)?

    public init(present: ((_ recipients: [String], _ body: String?) -> Void)? = nil) {
        self.present = present
    }

    // Best-effort capability hint. `MFMessageComposeViewController.canSendText()`
    // is @MainActor-isolated, so the AUTHORITATIVE check happens inside the
    // @MainActor `compose(...)` method below; this non-isolated property only
    // advertises that the path exists.
    public nonisolated var canSendMessages: Bool { true }

    public func compose(channel: MessageChannel, recipient: String?, body: String?) async throws {
        guard channel == .sms else {
            throw SmartEarsError.unsupported("SystemMessagingService only composes SMS/iMessage; channel=\(channel.rawValue).")
        }
        // Authoritative @MainActor capability check.
        guard MFMessageComposeViewController.canSendText() else {
            throw SmartEarsError.unsupported("This device cannot send SMS/iMessage.")
        }
        let recipients = recipient.map { [$0] } ?? []
        present?(recipients, body)
        // We can pre-fill, but the user MUST tap Send. Surface that honestly.
        throw SmartEarsError.userActionRequired(
            "Tap Send in Messages to deliver your text. Apps cannot auto-send SMS/iMessage."
        )
    }

    public func recentMessages(filter: AlertFilter) async throws -> [MessageSummary] {
        // HONEST LIMIT: there is no API to read the Messages database. Real inbound
        // visibility comes only from notification content we are entitled to, a
        // user share, or Gmail (for email). With nothing routed to us, we have
        // nothing to return.
        return []
    }
}

#else

// Non-UIKit / non-MessageUI fallback so the module still compiles everywhere.
@MainActor
public final class SystemMessagingService: MessagingService {
    public init() {}
    public nonisolated var canSendMessages: Bool { false }
    public func compose(channel: MessageChannel, recipient: String?, body: String?) async throws {
        throw SmartEarsError.unsupported("MessageUI is unavailable on this platform.")
    }
    public func recentMessages(filter: AlertFilter) async throws -> [MessageSummary] { [] }
}

#endif

// MARK: - Stub messaging service (no secrets, compiles & runs)

/// Mock messaging service returning realistic sample inbound messages so the app
/// compiles and runs with no entitlements. Composing reports `userActionRequired`
/// to mirror the real compose-only contract.
public final class StubMessagingService: MessagingService, @unchecked Sendable {
    public var canSendMessages: Bool { true }

    private let sampleMessages: [MessageSummary]

    public init(sampleMessages: [MessageSummary]? = nil) {
        self.sampleMessages = sampleMessages ?? StubMessagingService.defaultSamples
    }

    public func compose(channel: MessageChannel, recipient: String?, body: String?) async throws {
        // Mirror the real contract: we cannot auto-send; the user taps Send.
        throw SmartEarsError.userActionRequired(
            "Mock: would present a Messages compose sheet to \(recipient ?? "recipient"). User taps Send."
        )
    }

    public func recentMessages(filter: AlertFilter) async throws -> [MessageSummary] {
        switch filter {
        case .all: return sampleMessages
        case .unread: return sampleMessages.filter { !$0.isRead }
        case .importantOnly: return sampleMessages.filter { $0.importance >= .high }
        }
    }

    private static let defaultSamples: [MessageSummary] = [
        MessageSummary(
            channel: .sms,
            source: .simulated,
            senderName: "Mom",
            senderHandle: "+15551234567",
            preview: "Call me when you land, sweetie.",
            body: "Call me when you land, sweetie.",
            importance: .high,
            receivedAt: Date().addingTimeInterval(-600),
            isRead: false
        ),
        MessageSummary(
            channel: .sms,
            source: .userNotification,
            senderName: "Alex Rivera",
            senderHandle: "+15557654321",
            preview: "URGENT: prod is down, can you hop on?",
            body: nil, // notification-derived: full body may be unavailable
            importance: .urgent,
            receivedAt: Date().addingTimeInterval(-120),
            isRead: false
        ),
        MessageSummary(
            channel: .sms,
            source: .simulated,
            senderName: "Delivery",
            senderHandle: "262-66",
            preview: "Your package was delivered.",
            body: "Your package was delivered to the front door.",
            importance: .low,
            receivedAt: Date().addingTimeInterval(-3600),
            isRead: true
        )
    ]
}
