import Foundation

// MARK: - PersistedAppState
//
// The single Codable snapshot of all non-secret user state. Secrets stay in the
// Keychain (see KeychainCredentialStore); this holds only preferences and UI
// state. Decoding is tolerant: every field defaults so an older/partial blob (or
// a brand-new install) yields sensible values rather than throwing.

public struct PersistedAppState: Codable, Equatable, Sendable {
    public var hasCompletedOnboarding: Bool
    public var triggerConfig: TriggerConfig
    public var enabledInfoSources: Set<AppEnvironment.InfoSource>
    public var smartAlertingEnabled: Bool
    /// Whether AirPod tap-to-talk is enabled (claims the now-playing slot while
    /// armed). Defaults on; tolerant decode falls back to true for older blobs.
    public var airPodTapControlEnabled: Bool
    public var wakePhrase: String
    /// IDs of alerts the user has acknowledged (played/heard). Stored as IDs so
    /// it survives even though the alert list itself is currently re-seeded.
    public var acknowledgedAlertIDs: Set<SmartEarsID>

    public static let `default` = PersistedAppState(
        hasCompletedOnboarding: false,
        triggerConfig: .default,
        enabledInfoSources: Set(AppEnvironment.InfoSource.allCases),
        smartAlertingEnabled: true,
        airPodTapControlEnabled: true,
        wakePhrase: AppEnvironment.defaultWakePhrase,
        acknowledgedAlertIDs: []
    )

    public init(
        hasCompletedOnboarding: Bool = false,
        triggerConfig: TriggerConfig = .default,
        enabledInfoSources: Set<AppEnvironment.InfoSource> = Set(AppEnvironment.InfoSource.allCases),
        smartAlertingEnabled: Bool = true,
        airPodTapControlEnabled: Bool = true,
        wakePhrase: String = AppEnvironment.defaultWakePhrase,
        acknowledgedAlertIDs: Set<SmartEarsID> = []
    ) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.triggerConfig = triggerConfig
        self.enabledInfoSources = enabledInfoSources
        self.smartAlertingEnabled = smartAlertingEnabled
        self.airPodTapControlEnabled = airPodTapControlEnabled
        self.wakePhrase = wakePhrase
        self.acknowledgedAlertIDs = acknowledgedAlertIDs
    }

    // Tolerant decode: missing keys fall back to defaults (forward/backward compat).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PersistedAppState.default
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        triggerConfig = try c.decodeIfPresent(TriggerConfig.self, forKey: .triggerConfig) ?? d.triggerConfig
        enabledInfoSources = try c.decodeIfPresent(Set<AppEnvironment.InfoSource>.self, forKey: .enabledInfoSources) ?? d.enabledInfoSources
        smartAlertingEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartAlertingEnabled) ?? d.smartAlertingEnabled
        airPodTapControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .airPodTapControlEnabled) ?? d.airPodTapControlEnabled
        let phrase = (try c.decodeIfPresent(String.self, forKey: .wakePhrase) ?? d.wakePhrase)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        wakePhrase = phrase.isEmpty ? d.wakePhrase : phrase
        acknowledgedAlertIDs = try c.decodeIfPresent(Set<SmartEarsID>.self, forKey: .acknowledgedAlertIDs) ?? d.acknowledgedAlertIDs
    }
}

// MARK: - SettingsStoring
//
// Abstraction so previews/tests inject an in-memory double, mirroring the
// CredentialStoring pattern. The whole snapshot is read/written atomically.

public protocol SettingsStoring: Sendable {
    func load() -> PersistedAppState
    func save(_ state: PersistedAppState)
}

// MARK: - SettingsStore (UserDefaults)
//
// JSON-encodes the snapshot under one key. One key keeps the layer coherent and
// makes migration/wipe trivial. Never stores secrets (those live in Keychain).

public struct SettingsStore: SettingsStoring {
    public static let storageKey = "SmartEars.PersistedAppState.v1"
    // UserDefaults is thread-safe but not (yet) Sendable-annotated by Apple;
    // the store is only read/written synchronously, so this capture is safe.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = SettingsStore.storageKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PersistedAppState {
        guard let data = defaults.data(forKey: key) else { return .default }
        guard let decoded = try? JSONDecoder().decode(PersistedAppState.self, from: data) else { return .default }
        return decoded
    }

    public func save(_ state: PersistedAppState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - InMemorySettingsStore (previews/tests)

public final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private var state: PersistedAppState
    private let lock = NSLock()
    public init(_ seed: PersistedAppState = .default) { state = seed }
    public func load() -> PersistedAppState { lock.lock(); defer { lock.unlock() }; return state }
    public func save(_ newState: PersistedAppState) { lock.lock(); defer { lock.unlock() }; state = newState }
}
