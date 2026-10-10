import Combine
import CoreLocation
import Foundation
import UserNotifications

@MainActor
final class PlaceArrivalMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PlaceArrivalMonitor()
    @Published private(set) var enabledIDs: Set<UUID> = []
    @Published private(set) var arrivalPlace: LedgerPlace?
    @Published private(set) var visits: [PlaceVisit] = []
    @Published private(set) var pinnedIDs: Set<UUID> = []
    @Published private(set) var permissionMessage = "Arrival reminders are off"
    @Published private(set) var notificationMessage = "Checking notification permission…"
    @Published var error: String?

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private var owner = "guest"
    private var loadedOwner = false
    private var places: [LedgerPlace] = []
    private var entries: [LedgerEntry] = []
    private let prefix = "ledgerly.place."

    override init() {
        super.init()
        manager.delegate = self
        updatePermissionMessage()
        Task { await refreshNotificationPermission() }
    }

    func bootstrapAfterLaunch() {
        guard !loadedOwner else { return }
        let rememberedOwner = defaults.string(forKey: "ledgerly.monitor.lastOwner") ?? "guest"
        let repository = CoreDataLedgerRepository(accountID: rememberedOwner == "guest" ? nil : rememberedOwner)
        do {
            let savedPlaces = try repository.fetchPlaces()
            let savedEntries = try repository.fetchEntries()
            configure(places: savedPlaces, entries: savedEntries,
                      owner: rememberedOwner == "guest" ? nil : rememberedOwner)
            reconcileOpenVisits()
        } catch {
            self.error = "Could not restore arrival monitoring: \(error.localizedDescription)"
        }
    }

    func configure(places: [LedgerPlace], entries: [LedgerEntry], owner: String?) {
        let nextOwner = owner ?? "guest"
        let ownerChanged = nextOwner != self.owner || !loadedOwner
        if ownerChanged {
            stopLedgerlyRegions()
            self.owner = nextOwner
            defaults.set(nextOwner, forKey: "ledgerly.monitor.lastOwner")
            loadedOwner = true
            enabledIDs = Set((defaults.stringArray(forKey: preferenceKey("enabled")) ?? []).compactMap(UUID.init(uuidString:)))
            pinnedIDs = Set((defaults.stringArray(forKey: preferenceKey("pinned")) ?? []).compactMap(UUID.init(uuidString:)))
            visits = (defaults.data(forKey: preferenceKey("visits"))).flatMap {
                try? JSONDecoder().decode([PlaceVisit].self, from: $0)
            } ?? []
            arrivalPlace = nil
        } else if enabledIDs.isEmpty {
            enabledIDs = Set((defaults.stringArray(forKey: preferenceKey("enabled")) ?? []).compactMap(UUID.init(uuidString:)))
        }
        self.places = places
        self.entries = entries
        let existing = Set(places.map(\.id))
        if !enabledIDs.isSubset(of: existing) {
            enabledIDs.formIntersection(existing)
            persistEnabled()
        }
        if !pinnedIDs.isSubset(of: existing) {
            pinnedIDs.formIntersection(existing)
            persistPinned()
        }
        abandonStaleVisits()
        if ownerChanged {
            arrivalPlace = visits.first(where: { $0.isOpen }).flatMap { visit in
                guard let prompted = defaults.object(forKey: preferenceKey("prompt.\(visit.placeID.uuidString)")) as? Date,
                      prompted >= visit.enteredAt else { return nil }
                return places.first(where: { $0.id == visit.placeID })
            }
        }
        reconcile()
    }

    func isEnabled(_ place: LedgerPlace) -> Bool { enabledIDs.contains(place.id) }

    func isActive(_ place: LedgerPlace) -> Bool {
        manager.authorizationStatus == .authorizedAlways &&
        allocatedPlaces.contains(where: { $0.id == place.id })
    }

    var monitoredCount: Int { manager.authorizationStatus == .authorizedAlways ? allocatedPlaces.count : 0 }

    func isPinned(_ place: LedgerPlace) -> Bool { pinnedIDs.contains(place.id) }

    func setPinned(_ pinned: Bool, for place: LedgerPlace) {
        if pinned { pinnedIDs.insert(place.id) } else { pinnedIDs.remove(place.id) }
        persistPinned()
        reconcile()
    }

    func pausedReason(for place: LedgerPlace) -> String {
        if manager.authorizationStatus != .authorizedAlways { return permissionMessage }
        return "All 20 monitoring slots are in use. Pin this place or disable another reminder."
    }

    func hasReducedAccuracyWarning(for place: LedgerPlace) -> Bool {
        manager.accuracyAuthorization == .reducedAccuracy && radius(for: place) < 150
    }

    var needsSettings: Bool {
        if !CLLocationManager.locationServicesEnabled() { return true }
        return switch manager.authorizationStatus {
        case .authorizedWhenInUse, .denied, .restricted: true
        default: false
        }
    }

    func radius(for place: LedgerPlace) -> Double {
        let key = preferenceKey("radius.\(place.id.uuidString)")
        return defaults.object(forKey: key) == nil ? PlaceArrivalPolicy.defaultRadius :
            PlaceArrivalPolicy.radius(defaults.double(forKey: key))
    }

    func setRadius(_ radius: Double, for place: LedgerPlace) {
        defaults.set(PlaceArrivalPolicy.radius(radius), forKey: preferenceKey("radius.\(place.id.uuidString)"))
        reconcile()
    }

    func setEnabled(_ enabled: Bool, for place: LedgerPlace) {
        if enabled {
            guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
                error = "Arrival monitoring is unavailable on this device."
                return
            }
            enabledIDs.insert(place.id)
            manager.requestAlwaysAuthorization()
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await refreshNotificationPermission()
            }
        } else {
            enabledIDs.remove(place.id)
            closeVisit(for: place.id, at: .now, reconciled: true)
            if arrivalPlace?.id == place.id { arrivalPlace = nil }
        }
        persistEnabled()
        reconcile()
    }

    func dismissArrival() { arrivalPlace = nil }

    func refreshPermissions() async {
        updatePermissionMessage()
        await refreshNotificationPermission()
        reconcile()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updatePermissionMessage()
        reconcile()
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(prefix),
              let id = UUID(uuidString: String(region.identifier.split(separator: ".").last ?? "")),
              region.identifier == regionID(for: id),
              enabledIDs.contains(id),
              let place = places.first(where: { $0.id == id }) else { return }
        let key = preferenceKey("prompt.\(id.uuidString)")
        let now = Date()
        let open = visits.first(where: { $0.placeID == id && $0.isOpen })
        guard PlaceVisitPolicy.shouldCreateVisit(openVisit: open, at: now) else { return }
        if open != nil {
            closeVisit(for: id, at: now, reconciled: true, abandoned: true)
        }
        visits.insert(PlaceVisit(id: UUID(), placeID: id, placeName: place.name,
                                 enteredAt: now), at: 0)
        persistVisits()
        reconcile()
        guard PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                             lastPrompt: defaults.object(forKey: key) as? Date,
                                             entries: entries) else { return }
        defaults.set(now, forKey: key)
        arrivalPlace = place
        let content = UNMutableNotificationContent()
        content.title = "At \(place.name)?"
        content.body = "Record an expense if you bought something here."
        content.sound = .default
        content.categoryIdentifier = "LEDGERLY_PLACE"
        content.threadIdentifier = "ledgerly.places"
        content.userInfo = ["destination": "placeExpense:\(id.uuidString)"]
        let request = UNNotificationRequest(identifier: "place.\(owner).\(id.uuidString).\(Int(now.timeIntervalSince1970))",
                                            content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let id = UUID(uuidString: String(region.identifier.split(separator: ".").last ?? "")),
              region.identifier == regionID(for: id) else { return }
        closeVisit(for: id, at: .now)
    }

    func reconcileOpenVisits() {
        abandonStaleVisits()
        guard visits.contains(where: \.isOpen), manager.authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let now = Date()
        var changed = false
        for index in visits.indices where visits[index].isOpen {
            let place = places.first(where: { $0.id == visits[index].placeID })
            let updated = PlaceVisitPolicy.reconciled(visits[index], place: place,
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                radius: place.map { radius(for: $0) } ?? PlaceArrivalPolicy.defaultRadius,
                horizontalAccuracy: location.horizontalAccuracy, now: now)
            if updated != visits[index] {
                visits[index] = updated
                changed = true
            }
        }
        if changed {
            persistVisits()
            arrivalPlace = visits.first(where: { $0.isOpen }).flatMap { visit in
                places.first(where: { $0.id == visit.placeID })
            }
            reconcile()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = "Could not check an open visit: \(error.localizedDescription)"
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        self.error = "Could not monitor this place: \(error.localizedDescription)"
    }

    private func reconcile() {
        updatePermissionMessage()
        let active = manager.authorizationStatus == .authorizedAlways ? allocatedPlaces : []
        let desiredIDs = Set(active.map { regionID(for: $0.id) })
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) {
            guard let circular = region as? CLCircularRegion,
                  let place = active.first(where: { regionID(for: $0.id) == region.identifier }),
                  desiredIDs.contains(region.identifier),
                  abs(circular.center.latitude - place.latitude) < 0.000001,
                  abs(circular.center.longitude - place.longitude) < 0.000001,
                  abs(circular.radius - radius(for: place)) < 1 else {
                manager.stopMonitoring(for: region)
                continue
            }
        }
        for place in active {
            let identifier = regionID(for: place.id)
            if manager.monitoredRegions.contains(where: { region in
                guard let circular = region as? CLCircularRegion else { return false }
                return circular.identifier == identifier &&
                    abs(circular.center.latitude - place.latitude) < 0.000001 &&
                    abs(circular.center.longitude - place.longitude) < 0.000001 &&
                    abs(circular.radius - radius(for: place)) < 1
            }) { continue }
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: place.latitude,
                                                                           longitude: place.longitude),
                                          radius: radius(for: place), identifier: identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    private func stopLedgerlyRegions() {
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) {
            manager.stopMonitoring(for: region)
        }
    }

    private func updatePermissionMessage() {
        if !CLLocationManager.locationServicesEnabled() {
            permissionMessage = "Location Services are off for this iPhone"
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways: permissionMessage = "Arrival monitoring available"
        case .authorizedWhenInUse: permissionMessage = "Allow Always location in iPhone Settings for arrival alerts"
        case .denied, .restricted: permissionMessage = "Location access is off in iPhone Settings"
        case .notDetermined: permissionMessage = "Enable a place to request location access"
        @unknown default: permissionMessage = "Location permission unavailable"
        }
    }

    private func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: notificationMessage = "Arrival notifications allowed"
        case .denied: notificationMessage = "Notifications are off. Arrival cards remain available in the app."
        case .notDetermined: notificationMessage = "Notifications have not been requested"
        @unknown default: notificationMessage = "Notification status unavailable"
        }
    }

    private func preferenceKey(_ suffix: String) -> String { "ledgerly.monitor.\(owner).\(suffix)" }

    private func regionID(for id: UUID) -> String { "\(prefix)\(owner).\(id.uuidString)" }

    private func persistEnabled() {
        defaults.set(enabledIDs.map(\.uuidString).sorted(), forKey: preferenceKey("enabled"))
    }

    private func persistPinned() {
        defaults.set(pinnedIDs.map(\.uuidString).sorted(), forKey: preferenceKey("pinned"))
    }

    private var allocatedPlaces: [LedgerPlace] {
        PlaceArrivalPolicy.activePlaces(places, enabledIDs: enabledIDs,
                                        visits: visits, pinnedIDs: pinnedIDs)
    }

    private func persistVisits() {
        visits.sort { $0.enteredAt > $1.enteredAt }
        if visits.count > 500 { visits = Array(visits.prefix(500)) }
        if let data = try? JSONEncoder().encode(visits) {
            defaults.set(data, forKey: preferenceKey("visits"))
        }
    }

    private func abandonStaleVisits() {
        let now = Date()
        var changed = false
        for index in visits.indices where visits[index].isOpen &&
            now.timeIntervalSince(visits[index].enteredAt) >= PlaceVisitPolicy.abandonedAfter {
            visits[index] = PlaceVisitPolicy.closed(visits[index], at: now,
                                                    reconciled: true, abandoned: true)
            changed = true
        }
        if changed { persistVisits() }
    }

    private func closeVisit(for id: UUID, at date: Date, reconciled: Bool = false,
                            abandoned: Bool = false) {
        guard let index = visits.firstIndex(where: { $0.placeID == id && $0.isOpen }) else { return }
        visits[index] = PlaceVisitPolicy.closed(visits[index], at: date,
                                                reconciled: reconciled, abandoned: abandoned)
        let visit = visits[index]
        persistVisits()
        if arrivalPlace?.id == id { arrivalPlace = nil }
        reconcile()
        guard !abandoned && !reconciled else { return }
        let recorded = entries.filter { entry in
            entry.kind == .expense && entry.location?.placeID == id &&
            entry.date >= visit.enteredAt && entry.date <= (visit.exitedAt ?? date)
        }
        let total = recorded.reduce(Decimal.zero) { $0 + $1.amount }
        let content = UNMutableNotificationContent()
        content.title = "Left \(visit.placeName)"
        content.body = recorded.isEmpty ? "No expense was recorded for this visit." :
            "\(recorded.count) \(recorded.count == 1 ? "expense" : "expenses") · \(LKR.string(total)) recorded."
        content.categoryIdentifier = "LEDGERLY_PLACE_DEPARTURE"
        content.threadIdentifier = "ledgerly.places"
        content.userInfo = ["destination": "places"]
        let request = UNNotificationRequest(identifier: "departure.\(owner).\(visit.id.uuidString)",
                                            content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
