import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

// MARK: - Info / Weather
//
// `WeatherService` (the protocol) is the single source of truth declared in
// Models.swift — we do NOT redefine it here. This file provides:
//   * `WeatherSpeech` — a pure phrasing helper that turns a `WeatherSnapshot`
//     into a natural spoken sentence (the app's primary output surface is TTS).
//   * `WeatherKitWeatherService` — a real implementation backed by Apple's
//     WeatherKit, guarded with `#available` / `#if canImport`. WeatherKit needs
//     the WeatherKit capability + an Apple Developer entitlement; there is no API
//     key in source. On unsupported OS/SDK it throws so callers fall back to the
//     stub.
//   * `StubWeatherService` — returns a realistic `WeatherSnapshot` so the app
//     compiles and runs with NO secrets / entitlements present.
//
// Apple-platform reality: WeatherKit is entitlement-gated (not key-in-source),
// requires network + location authorization, and is only available iOS 16+.
// We keep all of that behind the protocol so the stub path is always usable.

// MARK: - Spoken phrasing helper

/// Pure, testable phrasing for weather snapshots. Kept separate from any
/// provider so both the live and stub services share identical speech output.
public enum WeatherSpeech {

    /// Phrases a weather report for speech, e.g.
    /// "In San Francisco it's 18 degrees and partly cloudy, with a high of 21
    ///  and a low of 13. Humidity is 60 percent and winds around 12 kilometers
    ///  per hour."
    public static func report(for snapshot: WeatherSnapshot, useFahrenheit: Bool = true) -> String {
        let unitWord = useFahrenheit ? "degrees" : "degrees Celsius"
        func temp(_ celsius: Double) -> Int {
            Int((useFahrenheit ? (celsius * 9 / 5 + 32) : celsius).rounded())
        }

        var sentence = "In \(snapshot.locationName) it's \(temp(snapshot.temperatureC)) \(unitWord) "
        sentence += "and \(snapshot.conditionDescription.lowercased())"

        if let high = snapshot.highC, let low = snapshot.lowC {
            sentence += ", with a high of \(temp(high)) and a low of \(temp(low))"
        } else if let high = snapshot.highC {
            sentence += ", with a high of \(temp(high))"
        }
        sentence += "."

        var extras: [String] = []
        if let humidity = snapshot.humidityPercent {
            extras.append("Humidity is \(humidity) percent")
        }
        if let wind = snapshot.windKph {
            extras.append("winds around \(Int(wind.rounded())) kilometers per hour")
        }
        if !extras.isEmpty {
            sentence += " " + extras.joined(separator: " and ") + "."
        }
        return sentence
    }
}

// MARK: - Live WeatherKit implementation

#if canImport(WeatherKit)
/// Real weather backed by Apple WeatherKit. Requires the WeatherKit capability
/// (entitlement) on the App ID — there is NO API key in source. Falls back to a
/// throw on unsupported OS so the `ServiceFactory` can select the stub instead.
@available(iOS 16.0, *)
public final class WeatherKitWeatherService: WeatherService {

    private let currentLocationProvider: @Sendable () async throws -> CLLocation

    /// - Parameter currentLocationProvider: injected so the (CoreLocation) auth
    ///   flow lives in the app layer; defaults to throwing `permissionDenied`
    ///   until wired to a real `CLLocationManager` provider.
    public init(
        currentLocationProvider: @escaping @Sendable () async throws -> CLLocation = {
            throw SmartEarsError.permissionDenied("location not yet authorized")
        }
    ) {
        self.currentLocationProvider = currentLocationProvider
    }

    public func currentWeather(location: String?) async throws -> WeatherSnapshot {
        let resolved = try await resolveLocation(location)
        let weather: Weather
        do {
            // Fully-qualified to disambiguate Apple's WeatherKit.WeatherService
            // from our protocol of the same name declared in Models.swift.
            weather = try await WeatherKit.WeatherService.shared.weather(for: resolved.location)
        } catch {
            throw SmartEarsError.network("WeatherKit fetch failed: \(error.localizedDescription)")
        }

        let current = weather.currentWeather
        let today = weather.dailyForecast.first

        return WeatherSnapshot(
            locationName: resolved.name,
            temperatureC: current.temperature.converted(to: .celsius).value,
            conditionDescription: current.condition.description,
            highC: today?.highTemperature.converted(to: .celsius).value,
            lowC: today?.lowTemperature.converted(to: .celsius).value,
            humidityPercent: Int((current.humidity * 100).rounded()),
            windKph: current.wind.speed.converted(to: .kilometersPerHour).value
        )
    }

    // MARK: Location resolution

    private struct ResolvedLocation { let name: String; let location: CLLocation }

    private func resolveLocation(_ query: String?) async throws -> ResolvedLocation {
        // CLGeocoder is not Sendable, so create it per-call rather than storing it.
        let geocoder = CLGeocoder()
        // Named location ("weather in Denver") -> forward-geocode.
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let placemarks = try await geocoder.geocodeAddressString(query)
            guard let placemark = placemarks.first, let location = placemark.location else {
                throw SmartEarsError.other("Could not find a location named \(query).")
            }
            return ResolvedLocation(name: placemark.locality ?? query, location: location)
        }

        // Current location ("weather") -> CoreLocation provider + reverse-geocode.
        let location = try await currentLocationProvider()
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        let name = placemarks?.first?.locality ?? "your area"
        return ResolvedLocation(name: name, location: location)
    }
}
#endif

// MARK: - Stub implementation

/// Realistic sample weather so the app runs with no entitlements/keys. Used by
/// `ServiceFactory` whenever WeatherKit is unavailable or unconfigured.
public final class StubWeatherService: WeatherService {

    private let sample: WeatherSnapshot

    public init(sample: WeatherSnapshot? = nil) {
        self.sample = sample ?? WeatherSnapshot(
            locationName: "San Francisco",
            temperatureC: 18,
            conditionDescription: "Partly cloudy",
            highC: 21,
            lowC: 13,
            humidityPercent: 62,
            windKph: 14
        )
    }

    public func currentWeather(location: String?) async throws -> WeatherSnapshot {
        // Echo the requested location name for a believable spoken response while
        // keeping the rest of the sample reading stable.
        let name = location?.trimmingCharacters(in: .whitespaces)
        guard let name, !name.isEmpty else { return sample }
        return WeatherSnapshot(
            locationName: name.capitalized,
            temperatureC: sample.temperatureC,
            conditionDescription: sample.conditionDescription,
            highC: sample.highC,
            lowC: sample.lowC,
            humidityPercent: sample.humidityPercent,
            windKph: sample.windKph
        )
    }
}
