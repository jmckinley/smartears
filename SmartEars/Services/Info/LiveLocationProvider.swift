//
//  LiveLocationProvider.swift
//  SmartEars — Info layer
//
//  A one-shot CoreLocation fetch used by `WeatherKitWeatherService` to resolve
//  the user's current location for local weather. It owns the (CoreLocation)
//  authorization flow so the weather service stays transport-agnostic.
//
//  Apple-platform reality:
//   * Location requires NSLocationWhenInUseUsageDescription (present in Info.plist).
//   * We request when-in-use authorization if not yet determined, then perform a
//     single `requestLocation()`. Denial throws `permissionDenied`; any delegate
//     failure throws `network`.
//

import Foundation
import CoreLocation

/// One-shot current-location provider built on `CLLocationManager`.
///
/// `@unchecked Sendable` is justified: all mutable state (`manager`,
/// `continuation`) is only ever touched on the main run loop that drives the
/// `CLLocationManagerDelegate` callbacks, and the continuation is resumed exactly
/// once via the `finish(...)` guard.
public final class LiveLocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    /// Convenience entry point matching `WeatherKitWeatherService`'s
    /// `currentLocationProvider` shape. Each call performs one fresh fetch.
    public static let current: @Sendable () async throws -> CLLocation = {
        try await LiveLocationProvider().location()
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    /// Fails the request if no fix / authorization decision arrives in time, so a
    /// weather query can never hang the assistant.
    private var timeoutTask: Task<Void, Never>?
    /// Serializes `finish` so the timeout and a delegate callback can't both resume.
    private let lock = NSLock()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Resolves the device's current location once, requesting authorization if
    /// it has not yet been determined.
    public func location() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)  // 8 s
                guard !Task.isCancelled else { return }
                self?.finish(.failure(SmartEarsError.network("Couldn't get your location for weather. Make sure Location is enabled for SmartEars.")))
            }
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                finish(.failure(SmartEarsError.permissionDenied("Location access denied.")))
            @unknown default:
                finish(.failure(SmartEarsError.permissionDenied("Location authorization is unavailable.")))
            }
        }
    }

    /// Resumes the pending continuation exactly once and clears it.
    private func finish(_ result: Result<CLLocation, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    // MARK: CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(SmartEarsError.permissionDenied("Location access denied.")))
        case .notDetermined:
            break // wait for the user's choice
        @unknown default:
            finish(.failure(SmartEarsError.permissionDenied("Location authorization is unavailable.")))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(SmartEarsError.network("No location was returned.")))
            return
        }
        finish(.success(location))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(SmartEarsError.network(error.localizedDescription)))
    }
}
