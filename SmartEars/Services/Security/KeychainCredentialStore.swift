import Foundation
import Security

// MARK: - CredentialStoring
//
// Abstraction over secure credential persistence so views/tests can inject an
// in-memory store while the app uses the real iOS Keychain. Keys are addressed
// by the same Info.plist token names used elsewhere (e.g. "SE_LLM_API_KEY").

public protocol CredentialStoring: Sendable {
    /// Returns the stored secret for `key`, or nil if absent/empty.
    func value(for key: String) -> String?
    /// Persists `value` for `key`. Returns true on success.
    @discardableResult func set(_ value: String, for key: String) -> Bool
    /// Removes any stored secret for `key`. Returns true on success (or if absent).
    @discardableResult func delete(for key: String) -> Bool
}

// MARK: - KeychainCredentialStore
//
// Keychain Services backed store (`kSecClassGenericPassword`). Secrets are
// written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable
// after the first unlock, never synced to iCloud, never leaves the device, and
// never written to source/UserDefaults. This is the secure home for the API
// keys a user pastes in Settings.

public struct KeychainCredentialStore: CredentialStoring {
    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "com.greatfallsventures.smartears") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    public func value(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    @discardableResult
    public func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(key)

        // Update in place if it already exists, otherwise add.
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecSuccess
        } else {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    @discardableResult
    public func delete(for key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - InMemoryCredentialStore
//
// Non-persistent store for SwiftUI previews and unit tests so they never touch
// the device Keychain.

public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    public init(_ seed: [String: String] = [:]) { store = seed }

    public func value(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let v = store[key]
        return (v?.isEmpty == false) ? v : nil
    }

    @discardableResult
    public func set(_ value: String, for key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
        return true
    }

    @discardableResult
    public func delete(for key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store[key] = nil
        return true
    }
}
