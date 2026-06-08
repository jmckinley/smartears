//
//  LiveContactResolver.swift
//  SmartEars — Comms layer
//
//  Resolves a spoken name ("text Mom") to a concrete recipient handle via the
//  Contacts framework (`CNContactStore`). Used by the tool router to address
//  outbound messages/emails by name.
//
//  Apple-platform reality:
//   * Reading contacts requires NSContactsUsageDescription (present in Info.plist)
//     and explicit user authorization. We request it on first use and throw
//     `permissionDenied` if it is not granted.
//

import Foundation
import Contacts

/// Live contact resolution backed by `CNContactStore`.
///
/// `@unchecked Sendable` is justified: `CNContactStore` is thread-safe for the
/// fetch operations used here, and the type holds no mutable state of its own.
public final class LiveContactResolver: ContactResolving, @unchecked Sendable {

    private let store = CNContactStore()

    public init() {}

    public func resolve(name: String) async throws -> ResolvedContact? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        try await requestAccess()

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        guard let contact = matches.first else { return nil }

        let displayName = CNContactFormatter.string(from: contact, style: .fullName) ?? trimmed
        let phone = contact.phoneNumbers.first?.value.stringValue
        let email = contact.emailAddresses.first.map { String($0.value) }

        return ResolvedContact(
            displayName: displayName,
            phoneNumber: phone,
            emailAddress: email
        )
    }

    /// Requests Contacts authorization, throwing `permissionDenied` if it is not
    /// granted. Already-authorized callers proceed without a prompt.
    private func requestAccess() async throws {
        let granted: Bool = try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { ok, error in
                if let error {
                    continuation.resume(throwing: SmartEarsError.other(error.localizedDescription))
                } else {
                    continuation.resume(returning: ok)
                }
            }
        }
        guard granted else {
            throw SmartEarsError.permissionDenied("Contacts access was not granted.")
        }
    }
}
