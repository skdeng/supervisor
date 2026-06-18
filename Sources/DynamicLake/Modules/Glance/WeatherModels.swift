import Foundation

/// A resolved snapshot of current conditions plus today's high/low for one location.
struct WeatherSnapshot: Equatable {
    /// Current temperature in the user's preferred unit.
    var temperature: Double
    /// Today's forecast high.
    var high: Double
    /// Today's forecast low.
    var low: Double
    /// WMO weather interpretation code for the current conditions.
    var conditionCode: Int
    /// Whether it is currently daytime at the location (drives sun vs. moon glyphs).
    var isDay: Bool
    /// Unit symbol to render after a temperature, e.g. "°" (degree only — Open-Meteo's
    /// unit is implied by the request).
    var unitSuffix: String
    /// Human-readable place name (locality), when reverse geocoding succeeds.
    var placeName: String?
    /// When this snapshot was produced.
    var fetchedAt: Date

    /// Current temperature rounded for display, e.g. "18°".
    var temperatureText: String { "\(Int(temperature.rounded()))\(unitSuffix)" }
    var highText: String { "\(Int(high.rounded()))\(unitSuffix)" }
    var lowText: String { "\(Int(low.rounded()))\(unitSuffix)" }

    /// Short human-readable description of the current conditions.
    var conditionDescription: String { WeatherCode.description(for: conditionCode) }
    /// SF Symbol name appropriate for the current conditions and day/night.
    var symbolName: String { WeatherCode.symbol(for: conditionCode, isDay: isDay) }
}

/// Maps WMO weather interpretation codes (as returned by Open-Meteo's `weather_code`
/// field) to SF Symbols and short descriptions. The full WMO 4677 table is collapsed to
/// the buckets Open-Meteo actually emits.
enum WeatherCode {
    /// SF Symbol for a WMO code, choosing day/night variants where they exist.
    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0:
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1:
            return isDay ? "sun.max.fill" : "moon.fill"
        case 2:
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55:
            return "cloud.drizzle.fill"
        case 56, 57:
            return "cloud.sleet.fill"
        case 61, 63, 65:
            return "cloud.rain.fill"
        case 66, 67:
            return "cloud.sleet.fill"
        case 71, 73, 75, 77:
            return "cloud.snow.fill"
        case 80, 81, 82:
            return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 85, 86:
            return "cloud.snow.fill"
        case 95:
            return "cloud.bolt.rain.fill"
        case 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return "cloud.fill"
        }
    }

    /// Short description for a WMO code.
    static func description(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51: return "Light drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light showers"
        case 81: return "Showers"
        case 82: return "Violent showers"
        case 85: return "Snow showers"
        case 86: return "Heavy snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm, hail"
        default: return "Unknown"
        }
    }
}

// MARK: - Open-Meteo response decoding

/// Top-level Open-Meteo forecast response (subset of fields we request).
struct OpenMeteoResponse: Decodable {
    let current: Current
    let daily: Daily
    let currentUnits: Units?

    enum CodingKeys: String, CodingKey {
        case current
        case daily
        case currentUnits = "current_units"
    }

    struct Current: Decodable {
        let temperature: Double
        let weatherCode: Int
        let isDay: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let temperatureMax: [Double]
        let temperatureMin: [Double]

        enum CodingKeys: String, CodingKey {
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
        }
    }

    struct Units: Decodable {
        let temperature: String?

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
        }
    }
}
