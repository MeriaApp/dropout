import CoreLocation

final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChanged: ((Bool) -> Void)?

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestAuthorization() {
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            // requestAlwaysAuthorization works for LSUIElement apps on macOS
            // The system prompt appears as a system alert
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            // User denied — can't re-prompt, would need to open System Settings
            print("dropout: location authorization denied — SSID names unavailable")
            print("dropout: enable in System Settings > Privacy & Security > Location Services")
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChanged?(isAuthorized)
    }
}
