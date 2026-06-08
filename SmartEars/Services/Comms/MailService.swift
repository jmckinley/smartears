import Foundation
import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif

// MARK: - MailService (COMMS layer)
//
// HONEST APPLE-PLATFORM REALITY CHECK (read me):
//  * Apple Mail content is NOT programmatically readable by third-party apps.
//    There is no public API to read Mail.app's inbox.
//  * Composing an Apple-Mail message is COMPOSE-ONLY via MFMailComposeViewController:
//    we pre-fill recipients/subject/body, but the USER must tap Send. Modeled as
//    `SmartEarsError.userActionRequired`.
//  * The ONLY third-party path with full inbound email bodies is the Gmail REST
//    API + OAuth 2.0. `GmailService` below is a skeleton for that path. It reads
//    its access token from the Keychain (placeholder; NO secrets in source) and
//    returns an empty/placeholder result until a real token is wired up, so the
//    app compiles and runs with no credentials.
//
// This file provides:
//  * `MailService`     — protocol conforming to the shared `EmailService`.
//  * `MailComposeView` — UIViewControllerRepresentable wrapping MFMailComposeViewController.
//  * `SystemMailService` — Apple-Mail compose-only impl (userActionRequired).
//  * `GmailService`    — Gmail REST API skeleton for READING + important detection.
//  * `StubMailService` — sample threads, no network, no secrets.

/// Result of presenting a system mail-compose sheet.
public enum MailComposeResult: Sendable, Equatable {
    case sent
    case saved        // saved as draft
    case cancelled
    case failed(String)
}

/// Focused COMMS-layer mail protocol. Conforms to the shared `EmailService`
/// (Models.swift): `recentEmails` (read) + `sendEmail` (compose / send).
public protocol MailService: EmailService {
    /// Whether this device can present an Apple-Mail compose sheet.
    var canSendMail: Bool { get }
}

#if canImport(UIKit) && canImport(MessageUI)

// MARK: - SwiftUI wrapper for MFMailComposeViewController

/// A SwiftUI wrapper around `MFMailComposeViewController`. Present from a SwiftUI
/// surface (e.g. `.sheet`) to let the user send Apple Mail. The user MUST tap
/// Send — we only pre-fill recipients/subject/body.
public struct MailComposeView: UIViewControllerRepresentable {
    public let recipients: [String]
    public let subject: String?
    public let body: String?
    public let onFinish: (MailComposeResult) -> Void

    public init(
        recipients: [String],
        subject: String? = nil,
        body: String? = nil,
        onFinish: @escaping (MailComposeResult) -> Void
    ) {
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.onFinish = onFinish
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    public func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        if !recipients.isEmpty { controller.setToRecipients(recipients) }
        if let subject { controller.setSubject(subject) }
        if let body { controller.setMessageBody(body, isHTML: false) }
        return controller
    }

    public func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    // The Coordinator is main-actor-isolated because UIKit drives its delegate
    // callbacks on the main thread. `@preconcurrency` quiets the cross-isolation
    // warning for the (nonisolated) UIKit delegate protocol.
    @MainActor
    public final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        private let onFinish: (MailComposeResult) -> Void
        init(onFinish: @escaping (MailComposeResult) -> Void) { self.onFinish = onFinish }

        public func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            let mapped: MailComposeResult
            if let error {
                mapped = .failed(error.localizedDescription)
            } else {
                switch result {
                case .sent: mapped = .sent
                case .saved: mapped = .saved
                case .cancelled: mapped = .cancelled
                case .failed: mapped = .failed("MailUI reported a send failure.")
                @unknown default: mapped = .failed("Unknown MailUI result.")
                }
            }
            controller.dismiss(animated: true) { [onFinish] in onFinish(mapped) }
        }
    }
}

// MARK: - Apple Mail (compose-only) service

/// Apple-Mail-backed mail service. Reading is NOT possible (no public API), so
/// `recentEmails` honestly returns nothing. Sending presents
/// `MFMailComposeViewController`; the user must tap Send.
@MainActor
public final class SystemMailService: MailService {
    /// Presenter the app wires up to show `MailComposeView`.
    public var present: ((_ recipients: [String], _ subject: String?, _ body: String?) -> Void)?

    public init(present: ((_ recipients: [String], _ subject: String?, _ body: String?) -> Void)? = nil) {
        self.present = present
    }

    // Best-effort capability hint. `MFMailComposeViewController.canSendMail()` is
    // @MainActor-isolated, so the AUTHORITATIVE check is performed inside the
    // @MainActor `sendEmail(...)` method below; this non-isolated property only
    // advertises that the path exists.
    public nonisolated var canSendMail: Bool { true }

    public func recentEmails(filter: AlertFilter) async throws -> [EmailSummary] {
        // HONEST LIMIT: Apple Mail content is not readable by third-party apps.
        // Use `GmailService` for inbound bodies.
        return []
    }

    public func sendEmail(recipient: String, subject: String, body: String) async throws {
        // Authoritative @MainActor capability check.
        guard MFMailComposeViewController.canSendMail() else {
            throw SmartEarsError.unsupported("No Apple Mail account is configured to send mail.")
        }
        present?([recipient], subject, body)
        throw SmartEarsError.userActionRequired(
            "Tap Send in Mail to deliver your email. Apps cannot auto-send Apple Mail."
        )
    }
}

#else

@MainActor
public final class SystemMailService: MailService {
    public init() {}
    public nonisolated var canSendMail: Bool { false }
    public func recentEmails(filter: AlertFilter) async throws -> [EmailSummary] { [] }
    public func sendEmail(recipient: String, subject: String, body: String) async throws {
        throw SmartEarsError.unsupported("MessageUI is unavailable on this platform.")
    }
}

#endif

// MARK: - Gmail REST API skeleton (READ + important-email detection)

/// Skeleton Gmail-backed mail service. This is the ONLY third-party path that can
/// read full inbound email bodies (Gmail REST API v1 + OAuth 2.0).
///
/// SECURITY: No secrets live in source. The OAuth access token is read from the
/// Keychain via `tokenProvider`. With no token present, calls cleanly throw
/// `SmartEarsError.missingCredential` so the caller falls back to a mock.
///
/// This is intentionally a skeleton: the request shapes and JSON decoding mirror
/// the real Gmail API so the integration is straightforward to complete, but it
/// does not perform live calls without a resolved token.
public final class GmailService: MailService, @unchecked Sendable {
    /// Supplies a valid OAuth access token (typically resolved from Keychain).
    /// Returns nil when no credential is available.
    public typealias TokenProvider = @Sendable () async -> String?

    private let tokenProvider: TokenProvider
    private let session: URLSession
    private let importanceScorer: ImportanceScorer
    private let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    public init(
        tokenProvider: @escaping TokenProvider = GmailService.keychainTokenProvider,
        session: URLSession = .shared,
        importanceScorer: ImportanceScorer = ImportanceScorer()
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.importanceScorer = importanceScorer
    }

    public var canSendMail: Bool { true } // Gmail API supports send (users.messages.send)

    // MARK: Keychain placeholder
    //
    // TODO: Replace with a real Keychain read (Keychain Services / a wrapper).
    //       Store the OAuth access/refresh tokens after the OAuth 2.0 flow
    //       (ASWebAuthenticationSession) completes. NEVER hardcode tokens.
    public static let keychainTokenProvider: TokenProvider = {
        // Placeholder: returns nil so we fall back to mock with no secrets.
        // Real impl: SecItemCopyMatching for service "com.greatfallsventures.smartears.gmail".
        return nil
    }

    // MARK: Reading

    public func recentEmails(filter: AlertFilter) async throws -> [EmailSummary] {
        guard let token = await tokenProvider(), !token.isEmpty else {
            // No credential -> caller should use StubMailService instead.
            throw SmartEarsError.missingCredential("Gmail OAuth token (use StubMailService for samples).")
        }
        // Real flow (left as skeleton):
        //  1. GET /messages?q=<query>&maxResults=N    -> list of message IDs
        //  2. GET /messages/{id}?format=full          -> headers + body parts
        //  3. Decode base64url body parts, extract From/Subject/snippet
        //  4. Score importance via `importanceScorer`
        let query = gmailQuery(for: filter)
        let listed = try await listMessageIDs(token: token, query: query, limit: 20)
        var summaries: [EmailSummary] = []
        for id in listed {
            if let summary = try await fetchMessage(token: token, id: id) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// Maps an `AlertFilter` to a Gmail search query string.
    private func gmailQuery(for filter: AlertFilter) -> String {
        switch filter {
        case .all: return "in:inbox"
        case .unread: return "in:inbox is:unread"
        case .importantOnly: return "in:inbox is:important"
        }
    }

    /// GET /messages — returns message IDs. Skeleton: builds the request honestly.
    private func listMessageIDs(token: String, query: String, limit: Int) async throws -> [String] {
        var components = URLComponents(url: baseURL.appendingPathComponent("messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(limit))
        ]
        let data = try await authorizedGET(url: components.url!, token: token)
        struct ListResponse: Decodable { struct Ref: Decodable { let id: String }; let messages: [Ref]? }
        do {
            let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
            return decoded.messages?.map(\.id) ?? []
        } catch {
            throw SmartEarsError.decoding("Gmail messages.list: \(error.localizedDescription)")
        }
    }

    /// GET /messages/{id} — fetches one message and maps it to an `EmailSummary`.
    private func fetchMessage(token: String, id: String) async throws -> EmailSummary? {
        let url = baseURL.appendingPathComponent("messages/\(id)")
        let data = try await authorizedGET(url: url, token: token)
        // Minimal Gmail message shape for header/snippet extraction.
        struct GmailMessage: Decodable {
            struct Header: Decodable { let name: String; let value: String }
            struct Payload: Decodable { let headers: [Header]? }
            let snippet: String?
            let labelIds: [String]?
            let payload: Payload?
        }
        let message: GmailMessage
        do {
            message = try JSONDecoder().decode(GmailMessage.self, from: data)
        } catch {
            throw SmartEarsError.decoding("Gmail messages.get: \(error.localizedDescription)")
        }
        let headers = message.payload?.headers ?? []
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let subject = header("Subject") ?? "(no subject)"
        let from = header("From") ?? "Unknown"
        let isUnread = message.labelIds?.contains("UNREAD") ?? false
        let isGmailImportant = message.labelIds?.contains("IMPORTANT") ?? false

        // Score importance: blend Gmail's own IMPORTANT label with our heuristic.
        let heuristic = importanceScorer.scoreEmail(from: from, subject: subject, snippet: message.snippet)
        let importance = importanceScorer.importance(for: max(heuristic, isGmailImportant ? 0.7 : 0.0))

        return EmailSummary(
            source: .gmailAPI,
            from: displayName(fromHeader: from),
            fromAddress: address(fromHeader: from),
            subject: subject,
            snippet: message.snippet,
            body: nil, // TODO: decode base64url body parts when full bodies needed
            importance: importance,
            receivedAt: Date(),
            isRead: !isUnread
        )
    }

    // MARK: Sending (Gmail users.messages.send)

    public func sendEmail(recipient: String, subject: String, body: String) async throws {
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw SmartEarsError.missingCredential("Gmail OAuth token required to send.")
        }
        // Real flow: build an RFC 2822 message, base64url-encode it, then
        // POST /messages/send with {"raw": "<encoded>"}. Skeleton below.
        _ = token
        throw SmartEarsError.unsupported("GmailService.sendEmail skeleton: wire up users.messages.send.")
    }

    // MARK: HTTP helper

    private func authorizedGET(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SmartEarsError.network("No HTTP response from Gmail.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SmartEarsError.network("Gmail returned HTTP \(http.statusCode).")
            }
            return data
        } catch let error as SmartEarsError {
            throw error
        } catch {
            throw SmartEarsError.network(error.localizedDescription)
        }
    }

    // MARK: From-header parsing ("Jane Doe <jane@x.com>")

    private func displayName(fromHeader: String) -> String {
        guard let range = fromHeader.range(of: " <") else { return fromHeader }
        let name = fromHeader[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? fromHeader : name
    }

    private func address(fromHeader: String) -> String? {
        guard let open = fromHeader.firstIndex(of: "<"),
              let close = fromHeader.firstIndex(of: ">"), open < close else {
            return fromHeader.contains("@") ? fromHeader.trimmingCharacters(in: .whitespaces) : nil
        }
        return String(fromHeader[fromHeader.index(after: open)..<close])
    }
}

// MARK: - Stub mail service (no secrets, compiles & runs)

/// Mock mail service returning realistic sample threads so the app compiles and
/// runs with no Gmail credentials. Sending reports `userActionRequired` to mirror
/// the compose-only Apple-Mail contract.
public final class StubMailService: MailService, @unchecked Sendable {
    public var canSendMail: Bool { true }

    private let sampleEmails: [EmailSummary]

    public init(sampleEmails: [EmailSummary]? = nil) {
        self.sampleEmails = sampleEmails ?? StubMailService.defaultSamples
    }

    public func recentEmails(filter: AlertFilter) async throws -> [EmailSummary] {
        switch filter {
        case .all: return sampleEmails
        case .unread: return sampleEmails.filter { !$0.isRead }
        case .importantOnly: return sampleEmails.filter { $0.importance >= .high }
        }
    }

    public func sendEmail(recipient: String, subject: String, body: String) async throws {
        throw SmartEarsError.userActionRequired(
            "Mock: would present a Mail compose sheet to \(recipient). User taps Send."
        )
    }

    private static let defaultSamples: [EmailSummary] = [
        EmailSummary(
            source: .gmailAPI,
            from: "Sarah Chen",
            fromAddress: "sarah.chen@greatfallsventures.com",
            subject: "URGENT: Board deck needs sign-off by 3pm",
            snippet: "Hi — we need your approval on slides 4-7 before the board call this afternoon...",
            body: "Hi — we need your approval on slides 4-7 before the board call this afternoon. Can you review ASAP? Thanks, Sarah",
            importance: .urgent,
            receivedAt: Date().addingTimeInterval(-900),
            isRead: false
        ),
        EmailSummary(
            source: .gmailAPI,
            from: "GitHub",
            fromAddress: "notifications@github.com",
            subject: "[smartears] PR #42 review requested",
            snippet: "alex-r requested your review on pull request #42: Add Comms layer...",
            body: nil,
            importance: .normal,
            receivedAt: Date().addingTimeInterval(-2400),
            isRead: false
        ),
        EmailSummary(
            source: .gmailAPI,
            from: "Weekly Digest",
            fromAddress: "digest@news.example.com",
            subject: "Your Monday roundup",
            snippet: "The 5 stories you should know this week...",
            body: nil,
            importance: .low,
            receivedAt: Date().addingTimeInterval(-7200),
            isRead: true
        )
    ]
}
