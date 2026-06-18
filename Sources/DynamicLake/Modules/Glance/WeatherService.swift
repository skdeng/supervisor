import CoreLocation
import Foundation
import MapKit

/// Authorization/availability state surfaced to the UI so it can show an inline prompt.
enum WeatherAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

/// Locates the user via CoreLocation (When-In-Use) and fetches current weather plus the
/// day's high/low from the free Open-Meteo API (no API key). All UI-facing state is
/// `@Published` and mutated on the main actor; network and geocoding I/O run off it.
@MainActor
final class WeatherService: NSObject, ObservableObject {
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var authState: WeatherAuthState = .notDetermined
    /// True while a fetch is in flight (location resolve + network).
    @Published private(set) var isLoading = false
    /// Last error message for diagnostics / inline display, if any.
    @Published private(set) var lastErrorMessage: String?

    private let manager = CLLocationManager()
    private let session: URLSession

    /// Continuations waiting for the next single-shot location fix.
    private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []
    private var refreshTimer: Timer?

    /// Whether to render temperatures in Fahrenheit. Derived from the current locale's
    /// measurement system at init; Open-Meteo is asked for the matching unit directly.
    private let useFahrenheit: Bool

    enum WeatherError: Error { case locationUnavailable, badResponse }

    override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        if #available(macOS 13.0, *) {
            self.useFahrenheit = Locale.current.measurementSystem == .us
        } else {
            self.useFahrenheit = !(Locale.current.usesMetricSystem)
        }

        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authState = Self.mapAuthorization(manager.authorizationStatus)
    }

    // MARK: Lifecycle

    /// Request location access (if needed) and begin periodic refresh.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            authState = .notDetermined
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            authState = .authorized
            Task { await self.refresh() }
        case .denied, .restricted:
            authState = .denied
        @unknown default:
            authState = .unavailable
        }

        // Refresh every 15 minutes while running.
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.authState == .authorized else { return }
                await self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        manager.stopUpdatingLocation()
        failAllWaiters(with: CancellationError())
    }

    /// Re-request authorization (used by the inline prompt after the user enables access).
    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: Fetch pipeline

    /// Resolve location, fetch weather, reverse-geocode the place name, publish a snapshot.
    func refresh() async {
        guard !isLoading else { return }
        guard authState == .authorized else { return }
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        do {
            let location = try await currentLocation()
            let response = try await fetchForecast(for: location.coordinate)

            let suffix = "°"
            let high = response.daily.temperatureMax.first ?? response.current.temperature
            let low = response.daily.temperatureMin.first ?? response.current.temperature

            var snap = WeatherSnapshot(
                temperature: response.current.temperature,
                high: high,
                low: low,
                conditionCode: response.current.weatherCode,
                isDay: response.current.isDay == 1,
                unitSuffix: suffix,
                placeName: snapshot?.placeName,
                fetchedAt: Date()
            )
            // Publish immediately; refine with place name when geocoding returns.
            snapshot = snap

            if let place = try? await reverseGeocode(location) {
                snap.placeName = place
                snapshot = snap
            }
        } catch is CancellationError {
            // Shutting down; leave the last good snapshot in place.
        } catch {
            lastErrorMessage = (error as NSError).localizedDescription
        }
    }

    /// Build and execute the Open-Meteo request for a coordinate.
    private func fetchForecast(for coordinate: CLLocationCoordinate2D) async throws -> OpenMeteoResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let tempUnit = useFahrenheit ? "fahrenheit" : "celsius"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: tempUnit),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        guard let url = components.url else { throw WeatherError.badResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.badResponse
        }
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }

    /// Reverse-geocode a location to a short locality name via MapKit, off the main actor.
    private nonisolated func reverseGeocode(_ location: CLLocation) async throws -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let mapItems = try await request.mapItems
        guard let item = mapItems.first else { return nil }
        // `name` for a reverse-geocoded coordinate is the locality/place; fall back to the
        // short postal address when no name is available.
        return item.name ?? item.address?.shortAddress
    }

    // MARK: Single-shot location

    /// Await one fresh location fix. Coalesces concurrent callers onto one `requestLocation`.
    private func currentLocation() async throws -> CLLocation {
        if let cached = manager.location, Date().timeIntervalSince(cached.timestamp) < 600 {
            return cached
        }
        return try await withCheckedThrowingContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 {
                manager.requestLocation()
            }
        }
    }

    private func resolveWaiters(with location: CLLocation) {
        let waiters = locationWaiters
        locationWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: location) }
    }

    private func failAllWaiters(with error: Error) {
        let waiters = locationWaiters
        locationWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    // MARK: Authorization mapping

    private static func mapAuthorization(_ status: CLAuthorizationStatus) -> WeatherAuthState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedAlways, .authorized: return .authorized
        case .denied, .restricted: return .denied
        @unknown default: return .unavailable
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let newState = Self.mapAuthorization(status)
            self.authState = newState
            if newState == .authorized {
                await self.refresh()
            } else {
                self.failAllWaiters(with: WeatherError.locationUnavailable)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.resolveWaiters(with: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.failAllWaiters(with: error)
            if self.snapshot == nil {
                self.lastErrorMessage = (error as NSError).localizedDescription
            }
        }
    }
}
