//
//  ComposePresenter.swift
//  SmartEars — Comms layer
//
//  Presents the system compose sheets (MFMessageComposeViewController /
//  MFMailComposeViewController) from the active key window's topmost view
//  controller. SMS/iMessage and Apple Mail are COMPOSE-ONLY — we pre-fill the
//  recipients/subject/body, but the user must tap Send.
//
//  `SystemMessagingService` / `SystemMailService` call into this presenter via
//  their injected `present` closures, so the voice-first flow can surface a
//  native compose sheet without the call site needing UIKit.
//
//  The `#else` branch below is a platform-compat no-op (e.g. on platforms without
//  MessageUI). It is NOT feature-stubbing — it exists only so the module compiles
//  everywhere; on iOS the real MessageUI path is always used.
//

import Foundation

#if canImport(MessageUI) && canImport(UIKit)

import UIKit
import MessageUI

/// Presents MessageUI compose sheets from the app's current top view controller
/// and retains a delegate for the lifetime of the sheet (releasing it on finish).
@MainActor
public final class ComposePresenter {

    public init() {}

    /// Holds the active delegate so it isn't deallocated while the sheet is up.
    /// Cleared when the sheet finishes (sent/cancelled/failed).
    private var activeDelegate: NSObject?

    // MARK: Public API

    /// Presents an SMS/iMessage compose sheet pre-filled with `recipients`/`body`.
    public func presentMessage(recipients: [String], body: String?) {
        guard MFMessageComposeViewController.canSendText() else {
            Self.presentUnavailableAlert(
                message: "This device can't send text messages right now."
            )
            return
        }
        guard let top = Self.topViewController() else {
            // No view controller to present from (no key window, hierarchy not
            // yet loaded, or app backgrounded). Surface this instead of silently
            // dropping the request so the user knows the sheet didn't open.
            Self.presentUnavailableAlert(
                message: "I couldn't open the Messages compose sheet right now. Please try again in a moment."
            )
            return
        }
        let controller = MFMessageComposeViewController()
        let delegate = MessageDelegate { [weak self] in self?.activeDelegate = nil }
        controller.messageComposeDelegate = delegate
        if !recipients.isEmpty { controller.recipients = recipients }
        if let body { controller.body = body }
        activeDelegate = delegate
        top.present(controller, animated: true)
    }

    /// Presents an Apple Mail compose sheet pre-filled with the given fields.
    public func presentMail(recipients: [String], subject: String?, body: String?) {
        guard MFMailComposeViewController.canSendMail() else {
            Self.presentUnavailableAlert(
                message: "Mail isn't set up on this device, so I can't open a compose sheet."
            )
            return
        }
        guard let top = Self.topViewController() else {
            Self.presentUnavailableAlert(
                message: "I couldn't open the Mail compose sheet right now. Please try again in a moment."
            )
            return
        }
        let controller = MFMailComposeViewController()
        let delegate = MailDelegate { [weak self] in self?.activeDelegate = nil }
        controller.mailComposeDelegate = delegate
        if !recipients.isEmpty { controller.setToRecipients(recipients) }
        if let subject { controller.setSubject(subject) }
        if let body { controller.setMessageBody(body, isHTML: false) }
        activeDelegate = delegate
        top.present(controller, animated: true)
    }

    // MARK: Top view controller discovery

    /// Walks from the active key window's root through any presented controllers
    /// to find the controller that should present the compose sheet. Falls back
    /// to any foreground-active scene's root window when no key window is set yet
    /// (a reachable state right after launch / returning from background).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Prefer the active scene; otherwise accept any connected scene.
        let candidateWindows = scenes
            .sorted { lhs, _ in lhs.activationState == .foregroundActive }
            .flatMap { $0.windows }
        // Prefer the key window, then any visible window, then any window at all.
        let window = candidateWindows.first { $0.isKeyWindow }
            ?? candidateWindows.first { !$0.isHidden }
            ?? candidateWindows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// Surfaces a user-facing alert when a compose sheet can't be presented, so a
    /// failed "send a text/email" request never fails silently. Best-effort: if no
    /// view controller exists at all, we log rather than crash.
    private static func presentUnavailableAlert(message: String) {
        guard let top = topViewController() else {
            print("[ComposePresenter] Compose unavailable and no view controller to alert from: \(message)")
            return
        }
        let alert = UIAlertController(title: "Couldn't Open Compose", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }

    // MARK: Retained delegates

    /// Dismisses the message sheet and releases the delegate on finish.
    private final class MessageDelegate: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        @MainActor
        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageUI.MessageComposeResult
        ) {
            controller.dismiss(animated: true) { [onFinish] in onFinish() }
        }
    }

    /// Dismisses the mail sheet and releases the delegate on finish.
    private final class MailDelegate: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        @MainActor
        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true) { [onFinish] in onFinish() }
        }
    }
}

#else

/// Platform-compat no-op presenter for platforms without MessageUI. Same API as
/// the real presenter so call sites compile everywhere; does nothing.
@MainActor
public final class ComposePresenter {
    public init() {}
    public func presentMessage(recipients: [String], body: String?) {}
    public func presentMail(recipients: [String], subject: String?, body: String?) {}
}

#endif
