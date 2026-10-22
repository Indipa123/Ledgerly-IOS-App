import ActivityKit
import AVFoundation
import Combine
import CoreLocation
import LocalAuthentication
import UserNotifications
import VisionKit

struct DeviceAccessStatus {
    let label: String
    let detail: String

    static let checking = DeviceAccessStatus(label: "Checking…", detail: "Reading device settings.")
}

@MainActor
final class PermissionOverviewService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var currentLocation = DeviceAccessStatus.checking
    @Published private(set) var arrivalMonitoring = DeviceAccessStatus.checking
    @Published private(set) var notifications = DeviceAccessStatus.checking
    @Published private(set) var camera = DeviceAccessStatus.checking
    @Published private(set) var authentication = DeviceAccessStatus.checking
    @Published private(set) var liveActivities = DeviceAccessStatus.checking
    @Published private(set) var isRefreshing = false

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    // Query access only. Permission requests remain in the feature that needs them.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let locationEnabled = await Task.detached(priority: .utility) {
            CLLocationManager.locationServicesEnabled()
        }.value
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        updateLocation(enabled: locationEnabled)
        updateNotifications(notificationSettings)
        updateCamera()
        updateAuthentication()
        liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
            ? .init(label: "Allowed", detail: "A shopping trip can appear on the Lock Screen and, on supported iPhones, Dynamic Island. Open a trip to start its Live Activity.")
            : .init(label: "Off", detail: "Live Activities are off for this app or device. You can track shopping items inside Ledgerly and review this setting in device Settings.")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { await refresh() }
    }

    private func updateLocation(enabled: Bool) {
        guard enabled else {
            let off = DeviceAccessStatus(label: "Location Services off",
                detail: "Enable Location Services in device Settings → Privacy & Security → Location Services. Saved places and manual map selection remain available.")
            currentLocation = off
            arrivalMonitoring = off
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            currentLocation = .init(label: "Not requested", detail: "Choose Use current location when adding a transaction or place to request access.")
            arrivalMonitoring = .init(label: "Not requested", detail: "Enable an arrival reminder for a saved place to set up background location access.")
        case .authorizedWhenInUse, .authorizedAlways:
            let precise = locationManager.accuracyAuthorization == .fullAccuracy
            currentLocation = .init(label: precise ? "Allowed · precise" : "Allowed · approximate",
                detail: precise ? "Ledgerly can get your current location while you use the app." :
                    "Ledgerly receives an approximate location. Check the pin before saving it, or enable Precise Location in device Settings.")
            if locationManager.authorizationStatus == .authorizedAlways {
                let monitoringAvailable = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
                arrivalMonitoring = .init(label: monitoringAvailable ? "Always allowed" : "Monitoring unavailable",
                    detail: monitoringAvailable ? "Enabled saved places can trigger arrival reminders and shopping trips in the background. iOS controls event delivery. Manage individual places in Places." :
                        "This device does not support region monitoring. Saved places and manually started shopping trips remain available.")
            } else {
                arrivalMonitoring = .init(label: "Always access needed",
                    detail: "Current location works while Ledgerly is open. Arrival reminders and automatic shopping trips are paused until Always location is allowed in device Settings.")
            }
        case .denied:
            currentLocation = .init(label: "Denied", detail: "Allow location for Ledgerly in device Settings to capture your current location. You can still search for a place or choose a map pin.")
            arrivalMonitoring = .init(label: "Paused", detail: "Arrival monitoring needs Always location access. Saved places remain available.")
        case .restricted:
            currentLocation = .init(label: "Restricted", detail: "Device restrictions prevent location access. You can still save a place by search or map pin.")
            arrivalMonitoring = .init(label: "Restricted", detail: "Device restrictions prevent arrival monitoring.")
        @unknown default:
            currentLocation = .init(label: "Unavailable", detail: "Location access could not be determined. Manual place selection remains available.")
            arrivalMonitoring = .init(label: "Unavailable", detail: "Arrival monitoring access could not be determined.")
        }
    }

    private func updateNotifications(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .notDetermined:
            notifications = .init(label: "Not requested", detail: "Enable budget alerts, create an active reminder, or enable a place's arrival reminder to request notifications.")
        case .denied:
            notifications = .init(label: "Denied", detail: "Allow notifications for Ledgerly in device Settings to receive reminders, budget alerts, and place arrival alerts.")
        case .authorized:
            notifications = settings.alertSetting == .enabled
                ? .init(label: "Allowed", detail: "Notifications are allowed. Individual budget alerts, payment reminders, and arrival reminders must also be enabled inside Ledgerly.")
                : .init(label: "Allowed · alerts off", detail: "Notifications are allowed, but visual alerts are off in device Settings. Review the delivery options there.")
        case .provisional:
            notifications = .init(label: "Quiet delivery", detail: "Notifications can be delivered quietly. Review banners and sounds in device Settings if you want visible alerts.")
        case .ephemeral:
            notifications = .init(label: "Temporary access", detail: "Notification access is temporary. Review its status in device Settings.")
        @unknown default:
            notifications = .init(label: "Unavailable", detail: "Notification access could not be determined.")
        }
    }

    private func updateCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            camera = .init(label: "Not requested", detail: "Choose Scan paper receipt while adding an expense to request camera access.")
        case .authorized:
            camera = .init(label: "Allowed", detail: "Camera access is allowed for scanning receipts. Review the recognised values before saving an expense.")
        case .denied:
            camera = .init(label: "Denied", detail: "Enable Camera for Ledgerly in device Settings to scan paper receipts. You can choose a receipt photo or enter the expense manually.")
        case .restricted:
            camera = .init(label: "Restricted", detail: "Device restrictions prevent camera access. Choose a receipt photo or enter the expense manually.")
        @unknown default:
            camera = .init(label: "Unavailable", detail: "Camera access could not be determined. Manual expense entry remains available.")
        }
        if !VNDocumentCameraViewController.isSupported {
            camera = .init(label: camera.label,
                detail: "Paper receipt scanning is unavailable on this device. Choose a receipt photo or enter the expense manually.")
        }
    }

    private func updateAuthentication() {
        let context = LAContext()
        var error: NSError?
        let canAuthenticate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        guard canAuthenticate else {
            authentication = .init(label: "Unavailable", detail: error?.code == LAError.passcodeNotSet.rawValue
                ? "Set a device passcode before enabling Ledgerly's app lock."
                : "Device authentication is unavailable. Check the passcode and biometric settings on this device.")
            return
        }
        var biometricError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError) {
            let method = context.biometryType == .faceID ? "Face ID" : "Touch ID"
            authentication = .init(label: "\(method) available", detail: "Enable App lock in Ledgerly Settings to protect your account view. Device passcode is available as a fallback.")
        } else {
            authentication = .init(label: "Device passcode available", detail: "App lock can use your device passcode. Biometrics are unavailable or need attention in device Settings.")
        }
    }
}
