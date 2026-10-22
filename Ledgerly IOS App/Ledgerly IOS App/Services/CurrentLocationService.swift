import CoreLocation
import Combine

@MainActor
final class CurrentLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var isLocating = false
    @Published private(set) var errorMessage: String?

    private let manager = CLLocationManager()
    private var hasPendingRequest = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func locate() {
        guard !isLocating else { return }
        location = nil
        errorMessage = nil
        isLocating = true
        hasPendingRequest = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            fail("Location access is off. Enable it for Ledgerly in Settings, or choose a point on the map.")
        @unknown default:
            fail("Location is unavailable. Choose a point on the map instead.")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard hasPendingRequest else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            fail("Location access is off. Enable it for Ledgerly in Settings, or choose a point on the map.")
        case .notDetermined:
            break
        @unknown default:
            fail("Location is unavailable. Choose a point on the map instead.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard hasPendingRequest else { return }
        guard let latest = locations.last(where: { $0.horizontalAccuracy >= 0 }) else {
            fail("This device could not determine a usable location. Try again or choose a point on the map.")
            return
        }
        hasPendingRequest = false
        isLocating = false
        location = latest
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard hasPendingRequest else { return }
        fail("This device could not determine your location. Try again or choose a point on the map.")
    }

    private func fail(_ message: String) {
        hasPendingRequest = false
        isLocating = false
        errorMessage = message
    }
}
