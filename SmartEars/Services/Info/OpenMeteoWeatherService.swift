import Foundation
import CoreLocation

// MARK: - OpenMeteoWeatherService (free, NO API key)
//
// Uses Open-Meteo (https://open-meteo.com) for current conditions — completely
// free, no key, no signup. Coordinates come from:
//   • a spoken city name  -> Open-Meteo's free geocoding API, or
//   • the device location -> injected `locationProvider` (CoreLocation), with a
//     reverse-geocode (CLGeocoder, also free) for a friendly place name.
//
// This replaces the WeatherKit path so weather works with zero setup and no
// entitlement. WeatherKitWeatherService remains available if you prefer it.

public struct OpenMeteoWeatherService: WeatherService {

    private let session: URLSession
    private let locationProvider: @Sendable () async throws -> CLLocation

    public init(
        session: URLSession = .shared,
        locationProvider: @escaping @Sendable () async throws -> CLLocation = LiveLocationProvider.current
    ) {
        self.session = session
        self.locationProvider = locationProvider
    }

    public func currentWeather(location: String?) async throws -> WeatherSnapshot {
        let place = try await resolvePlace(location)
        return try await fetch(lat: place.lat, lon: place.lon, name: place.name)
    }

    // MARK: Coordinate resolution

    private struct Place { let lat: Double; let lon: Double; let name: String }

    private func resolvePlace(_ query: String?) async throws -> Place {
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return try await geocode(query)            // city name -> coordinates
        }
        // No city given: use the device location, then reverse-geocode for a name.
        let loc = try await locationProvider()
        let name = (try? await reverseGeocode(loc)) ?? "your location"
        return Place(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, name: name)
    }

    /// Forward geocode a place name via Open-Meteo's free geocoding API.
    private func geocode(_ query: String) async throws -> Place {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "1")]
        let (data, _) = try await session.data(from: c.url!)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = obj?["results"] as? [[String: Any]], let first = results.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double
        else { throw SmartEarsError.other("I couldn't find a place called \(query).") }
        let name = (first["name"] as? String) ?? query
        return Place(lat: lat, lon: lon, name: name)
    }

    private func reverseGeocode(_ loc: CLLocation) async throws -> String? {
        let marks = try await CLGeocoder().reverseGeocodeLocation(loc)
        return marks.first?.locality ?? marks.first?.administrativeArea
    }

    // MARK: Forecast fetch

    private func fetch(lat: Double, lon: Double, name: String) async throws -> WeatherSnapshot {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "temperature_unit", value: "celsius"),
            .init(name: "wind_speed_unit", value: "kmh"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        let (data, response) = try await session.data(from: c.url!)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw SmartEarsError.network("Weather service returned an error.")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = obj["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double
        else { throw SmartEarsError.network("Couldn't read the weather data.") }

        let daily = obj["daily"] as? [String: Any]
        func firstD(_ key: String) -> Double? { (daily?[key] as? [Double])?.first }

        return WeatherSnapshot(
            locationName: name,
            temperatureC: temp,
            conditionDescription: Self.describe(code: current["weather_code"] as? Int ?? -1),
            highC: firstD("temperature_2m_max"),
            lowC: firstD("temperature_2m_min"),
            humidityPercent: (current["relative_humidity_2m"] as? Double).map { Int($0.rounded()) }
                ?? (current["relative_humidity_2m"] as? Int),
            windKph: current["wind_speed_10m"] as? Double
        )
    }

    /// WMO weather-code -> human description.
    static func describe(code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzly"
        case 56, 57: return "freezing drizzle"
        case 61, 63, 65: return "rainy"
        case 66, 67: return "freezing rain"
        case 71, 73, 75, 77: return "snowy"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "unsettled"
        }
    }
}
