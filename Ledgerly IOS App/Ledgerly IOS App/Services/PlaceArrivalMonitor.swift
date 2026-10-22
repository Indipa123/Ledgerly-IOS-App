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
    @Published private(set) var shoppingRules: [UUID: ShoppingArrivalRule] = [:]
    @Published private(set) var mutedIDs: Set<UUID> = []
    @Published private(set) var automaticMutingEnabled = true
    @Published private(set) var promptFeedback: [UUID: PlacePromptDismissalState] = [:]
    @Published private(set) var quietHours = PlaceQuietHours()
    @Published private(set) var notificationPreferences = PlaceNotificationPreferences()
    @Published private(set) var permissionMessage = "Arrival reminders are off"
    @Published private(set) var notificationMessage = "Checking notification permission…"
    @Published private(set) var monitoredIDs: Set<UUID> = []
    @Published var error: String?

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private var owner = "guest"
    private var loadedOwner = false
    private var places: [LedgerPlace] = []
    private var entries: [LedgerEntry] = []
    private var dismissedArrivalVisitIDs: Set<UUID> = []
    private var presentedArrivalVisitIDs: Set<UUID> = []
    private var automaticMutingChangedAt: Date?
    private var pendingRegionIDs: Set<String> = []
    private var failedRegionIDs: Set<String> = []
    private var notificationStatus: UNAuthorizationStatus = .notDetermined
    private var notificationAuthorizationTask: Task<Void, Never>?
    private let prefix = "ledgerly.place."

    var accountKey: String { owner }

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
            self.error = "Place reminders could not be restored. Open Places and check monitoring."
        }
    }

    func configure(places: [LedgerPlace], entries: [LedgerEntry], owner: String?) {
        if let owner, AccountDeletionJournal.shared.contains(owner) {
            suspendForAccountDeletion(owner)
            return
        }
        let nextOwner = owner ?? "guest"
        let ownerChanged = nextOwner != self.owner || !loadedOwner
        if ownerChanged {
            if loadedOwner { cancelPendingPlaceNotifications() }
            stopLedgerlyRegions()
            self.owner = nextOwner
            defaults.set(nextOwner, forKey: "ledgerly.monitor.lastOwner")
            loadedOwner = true
            enabledIDs = Set((defaults.stringArray(forKey: preferenceKey("enabled")) ?? []).compactMap(UUID.init(uuidString:)))
            pinnedIDs = Set((defaults.stringArray(forKey: preferenceKey("pinned")) ?? []).compactMap(UUID.init(uuidString:)))
            let savedRules = defaults.data(forKey: preferenceKey("shoppingRules")).flatMap {
                try? JSONDecoder().decode([UUID: ShoppingArrivalRule].self, from: $0)
            }
            shoppingRules = savedRules ?? [:]
            mutedIDs = Set((defaults.stringArray(forKey: preferenceKey("muted")) ?? []).compactMap(UUID.init(uuidString:)))
            automaticMutingEnabled = defaults.object(forKey: preferenceKey("automaticMuteEnabled")) as? Bool ?? true
            automaticMutingChangedAt = defaults.object(forKey: preferenceKey("automaticMuteChangedAt")) as? Date
            promptFeedback = defaults.data(forKey: preferenceKey("promptFeedback")).flatMap {
                try? JSONDecoder().decode([UUID: PlacePromptDismissalState].self, from: $0)
            } ?? [:]
            dismissedArrivalVisitIDs = Set((defaults.stringArray(forKey: preferenceKey("dismissedArrivals")) ?? []).compactMap(UUID.init(uuidString:)))
            presentedArrivalVisitIDs = Set((defaults.stringArray(forKey: preferenceKey("arrivalCardVisits")) ?? []).compactMap(UUID.init(uuidString:)))
            let savedHours = defaults.data(forKey: preferenceKey("quietHours")).flatMap {
                try? JSONDecoder().decode(PlaceQuietHours.self, from: $0)
            }
            if let savedHours, savedHours.isValid { quietHours = savedHours }
            else { quietHours = PlaceQuietHours() }
            notificationPreferences = defaults.data(forKey: preferenceKey("notifications")).flatMap {
                try? JSONDecoder().decode(PlaceNotificationPreferences.self, from: $0)
            } ?? PlaceNotificationPreferences()
            visits = (defaults.data(forKey: preferenceKey("visits"))).flatMap {
                try? JSONDecoder().decode([PlaceVisit].self, from: $0)
            } ?? []
            arrivalPlace = nil
        } else if enabledIDs.isEmpty {
            enabledIDs = Set((defaults.stringArray(forKey: preferenceKey("enabled")) ?? []).compactMap(UUID.init(uuidString:)))
        }
        let recordedPlaceIDs = ownerChanged ? [] :
            PlacePromptFeedbackPolicy.newlyRecordedPlaceIDs(previous: self.entries, current: entries)
        self.places = places
        self.entries = entries
        let existing = Set(places.map(\.id))
        let previousFeedback = promptFeedback
        promptFeedback = promptFeedback.filter { existing.contains($0.key) }
        for id in recordedPlaceIDs where existing.contains(id) {
            var state = promptFeedback[id] ?? .init()
            state.reset(at: .now)
            promptFeedback[id] = state
        }
        if promptFeedback != previousFeedback { persistPromptFeedback() }
        if !enabledIDs.isSubset(of: existing) {
            enabledIDs.formIntersection(existing)
            persistEnabled()
        }
        if !pinnedIDs.isSubset(of: existing) {
            pinnedIDs.formIntersection(existing)
            persistPinned()
        }
        if !mutedIDs.isSubset(of: existing) {
            mutedIDs.formIntersection(existing)
            persistMuted()
        }
        let validRules = shoppingRules.filter { existing.contains($0.key) }
        if validRules.count != shoppingRules.count {
            shoppingRules = validRules
            persistShoppingRules()
        }
        abandonStaleVisits()
        refreshArrivalCard()
        reconcile()
    }

    func isEnabled(_ place: LedgerPlace) -> Bool { enabledIDs.contains(place.id) }

    func isMuted(_ place: LedgerPlace) -> Bool { isPlaceMuted(place.id) }

    func isAutomaticallyMuted(_ place: LedgerPlace) -> Bool {
        automaticMutingEnabled && promptFeedback[place.id]?.isAutomaticallyMuted == true
    }

    func dismissalStreak(for place: LedgerPlace) -> Int {
        automaticMutingEnabled ? (promptFeedback[place.id]?.streak ?? 0) : 0
    }

    func setAutomaticMutingEnabled(_ enabled: Bool) {
        guard enabled != automaticMutingEnabled else { return }
        automaticMutingEnabled = enabled
        automaticMutingChangedAt = .now
        promptFeedback = [:]
        defaults.set(enabled, forKey: preferenceKey("automaticMuteEnabled"))
        defaults.set(automaticMutingChangedAt, forKey: preferenceKey("automaticMuteChangedAt"))
        persistPromptFeedback()
        refreshArrivalCard()
    }

    func setMuted(_ muted: Bool, for place: LedgerPlace) {
        guard places.contains(where: { $0.id == place.id }) else { return }
        if muted {
            mutedIDs.insert(place.id)
            dismissArrival(for: place.id)
        } else {
            mutedIDs.remove(place.id)
            var state = promptFeedback[place.id] ?? .init()
            state.reset(at: .now)
            promptFeedback[place.id] = state
            persistPromptFeedback()
        }
        persistMuted()
        refreshArrivalCard()
    }

    @discardableResult
    func setQuietHours(_ hours: PlaceQuietHours) -> Bool {
        guard !hours.enabled || hours.isValid else {
            error = "Choose different start and end times for quiet hours."
            return false
        }
        let validHours = hours.isValid ? hours : PlaceQuietHours()
        guard let data = try? JSONEncoder().encode(validHours) else { return false }
        quietHours = validHours
        defaults.set(data, forKey: preferenceKey("quietHours"))
        refreshArrivalCard()
        if validHours.contains(.now) { cancelPendingPlaceNotifications() }
        return true
    }

    func shoppingRule(for place: LedgerPlace) -> ShoppingArrivalRule? { shoppingRules[place.id] }

    func setNotificationPreferences(_ preferences: PlaceNotificationPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        notificationPreferences = preferences
        defaults.set(data, forKey: preferenceKey("notifications"))
        if !preferences.departureEnabled {
            let expectedOwner = owner
            Task {
                let center = UNUserNotificationCenter.current()
                let requests = await center.pendingNotificationRequests()
                guard self.owner == expectedOwner, !self.notificationPreferences.departureEnabled else { return }
                center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier)
                    .filter { $0.hasPrefix("departure.\(expectedOwner).") })
            }
        }
    }

    private func notificationSound(_ style: PlaceAlertSound, for kind: PlaceAlertKind) -> UNNotificationSound? {
        switch style {
        case .silent: return nil
        case .system: return .default
        case .chime:
            return style.filename(for: kind).map { UNNotificationSound(named: UNNotificationSoundName(rawValue: $0)) }
        }
    }

    func sendTestNotification(_ kind: PlaceAlertKind, sound: PlaceAlertSound) async throws {
        guard !AccountDeletionJournal.shared.contains(owner) else { return }
        let expectedOwner = owner
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshNotificationPermission()
        guard owner == expectedOwner, !AccountDeletionJournal.shared.contains(expectedOwner) else { return }
        guard notificationStatus == .authorized || notificationStatus == .provisional || notificationStatus == .ephemeral else {
            throw NSError(domain: "LedgerlyPlaceNotifications", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Allow Ledgerly notifications in device Settings, then try again."])
        }
        let content = UNMutableNotificationContent()
        content.title = kind == .arrival ? "Ledgerly arrival test" : "Ledgerly departure test"
        content.body = "This tests notification delivery and your selected sound. No visit or expense was recorded."
        content.sound = notificationSound(sound, for: kind)
        content.threadIdentifier = "ledgerly.places"
        content.userInfo = ["destination": "places"]
        let id = "placeTest.\(expectedOwner).\(kind.rawValue)"
        try await center.add(UNNotificationRequest(identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
        if owner != expectedOwner || AccountDeletionJournal.shared.contains(expectedOwner) {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    func setShoppingRule(_ rule: ShoppingArrivalRule?, for place: LedgerPlace) {
        if let rule, rule.cap > 0, isEnabled(place) { shoppingRules[place.id] = rule }
        else { shoppingRules.removeValue(forKey: place.id) }
        persistShoppingRules()
    }

    func isActive(_ place: LedgerPlace) -> Bool {
        manager.authorizationStatus == .authorizedAlways &&
        monitoredIDs.contains(place.id)
    }

    var monitoredCount: Int { monitoredIDs.count }

    func status(for place: LedgerPlace) -> String {
        if !isActive(place) { return "Arrival reminder paused · \(pausedReason(for: place))" }
        if isMuted(place) { return "Place alerts muted" }
        if quietHours.contains(.now) { return "Monitoring · quiet hours active" }
        if notificationStatus == .denied { return "Monitoring · notifications disabled" }
        return "Arrival monitoring on"
    }

    func isPinned(_ place: LedgerPlace) -> Bool { pinnedIDs.contains(place.id) }

    func setPinned(_ pinned: Bool, for place: LedgerPlace) {
        if pinned { pinnedIDs.insert(place.id) } else { pinnedIDs.remove(place.id) }
        persistPinned()
        reconcile()
    }

    func pausedReason(for place: LedgerPlace) -> String {
        if manager.authorizationStatus != .authorizedAlways { return permissionMessage }
        if failedRegionIDs.contains(regionID(for: place.id)) { return "Registration failed. Check monitoring to retry." }
        if allocatedPlaces.contains(where: { $0.id == place.id }) { return "Starting reminders…" }
        return "All 20 monitoring slots are in use. Pin this place or disable another reminder."
    }

    func hasReducedAccuracyWarning(for place: LedgerPlace) -> Bool {
        manager.accuracyAuthorization == .reducedAccuracy && radius(for: place) < 150
    }

    var needsSettings: Bool {
        // Core Location reports disabled services through authorizationStatus.
        // Avoid a synchronous system-wide query whenever SwiftUI reads this value.
        if notificationStatus == .denied { return true }
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
            notificationAuthorizationTask = Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await refreshNotificationPermission()
            }
        } else {
            enabledIDs.remove(place.id)
            shoppingRules.removeValue(forKey: place.id)
            persistShoppingRules()
            closeVisit(for: place.id, at: .now, reconciled: true)
            if arrivalPlace?.id == place.id { arrivalPlace = nil }
        }
        persistEnabled()
        reconcile()
    }

    func dismissArrival(for placeID: UUID? = nil, explicitlyDismissed: Bool = false) {
        guard let id = placeID ?? arrivalPlace?.id else { return }
        if let visit = visits.first(where: { $0.placeID == id && $0.isOpen }) {
            dismissVisit(visit, explicitlyDismissed: explicitlyDismissed)
        } else {
            if arrivalPlace?.id == id { arrivalPlace = nil }
            cancelPendingPlaceNotifications(for: id, includeDelivered: true)
        }
    }

    func dismissArrivalNotification(owner expectedOwner: String, visitID: UUID) {
        bootstrapAfterLaunch()
        guard expectedOwner == owner,
              let visit = visits.first(where: { $0.id == visitID }),
              enabledIDs.contains(visit.placeID),
              places.contains(where: { $0.id == visit.placeID }) else { return }
        dismissVisit(visit, explicitlyDismissed: true)
    }

    private func dismissVisit(_ visit: PlaceVisit, explicitlyDismissed: Bool) {
        let firstDismissal = dismissedArrivalVisitIDs.insert(visit.id).inserted
        let hasExpense = entries.contains {
            $0.kind == .expense && $0.location?.placeID == visit.placeID &&
                $0.date >= visit.enteredAt && $0.date <= (visit.exitedAt ?? .now)
        }
        if explicitlyDismissed, firstDismissal, automaticMutingEnabled, !hasExpense,
           presentedArrivalVisitIDs.contains(visit.id), !isPlaceMuted(visit.placeID) {
            var state = promptFeedback[visit.placeID] ?? .init()
            if state.dismiss(visit: visit, at: .now, enabledAfter: automaticMutingChangedAt) {
                promptFeedback[visit.placeID] = state
                persistPromptFeedback()
            }
        }
        persistDismissedArrivals()
        if visit.isOpen || isPlaceMuted(visit.placeID) {
            if arrivalPlace?.id == visit.placeID { arrivalPlace = nil }
            cancelPendingPlaceNotifications(for: visit.placeID, includeDelivered: true)
        }
        refreshArrivalCard()
    }

    func refreshPermissions() async {
        updatePermissionMessage()
        await refreshNotificationPermission()
        error = nil
        for region in manager.monitoredRegions where failedRegionIDs.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        failedRegionIDs.removeAll()
        reconcile()
        // Registration alone does not report an arrival when already inside.
        for region in manager.monitoredRegions where currentPlace(for: region) != nil {
            manager.requestState(for: region)
        }
        refreshArrivalCard()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updatePermissionMessage()
        reconcile()
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        handleArrival(in: region)
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        pendingRegionIDs.remove(region.identifier)
        guard let place = currentPlace(for: region) else { return }
        failedRegionIDs.remove(region.identifier)
        monitoredIDs.insert(place.id)
        manager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState,
                         for region: CLRegion) {
        guard let place = currentPlace(for: region) else { return }
        if state == .inside { handleArrival(in: region) }
        else if state == .outside { closeVisit(for: place.id, at: .now, reconciled: true) }
    }

    private func currentPlace(for region: CLRegion) -> LedgerPlace? {
        guard manager.authorizationStatus == .authorizedAlways,
              let circular = region as? CLCircularRegion else { return nil }
        return allocatedPlaces.first {
            region.identifier == regionID(for: $0.id) &&
                abs(circular.center.latitude - $0.latitude) < 0.000001 &&
                abs(circular.center.longitude - $0.longitude) < 0.000001 &&
                abs(circular.radius - radius(for: $0)) < 1
        }
    }

    private func handleArrival(in region: CLRegion) {
        guard let place = currentPlace(for: region) else { return }
        let id = place.id
        let key = preferenceKey("prompt.\(id.uuidString)")
        let now = Date()
        let open = visits.first(where: { $0.placeID == id && $0.isOpen })
        guard PlaceVisitPolicy.shouldCreateVisit(openVisit: open, at: now) else { return }
        if open != nil {
            closeVisit(for: id, at: now, reconciled: true, abandoned: true)
        }
        let visit = PlaceVisit(id: UUID(), placeID: id, placeName: place.name, enteredAt: now)
        visits.insert(visit, at: 0)
        persistVisits()
        reconcile()
        guard PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                             lastPrompt: defaults.object(forKey: key) as? Date,
                                             entries: entries) else { return }
        let content = UNMutableNotificationContent()
        let rule = shoppingRules[id]
        var categoryAvailable = true
        var hasExistingTrip = false
        var started = false
        if let rule {
            let accountID = owner == "guest" ? nil : owner
            let trips = ShoppingTripStore(accountID: accountID)
            hasExistingTrip = trips.activeTrip != nil
            let repository = CoreDataLedgerRepository(accountID: accountID)
            categoryAvailable = ((try? repository.fetchCategories()) ?? []).contains {
                $0.id == rule.categoryID && $0.kind == .expense && !$0.isArchived
            }
            if rule.canStart(activeTrip: trips.activeTrip, categoryAvailable: categoryAvailable) {
                started = trips.start(name: place.name, cap: rule.cap, categoryID: rule.categoryID,
                                      eventID: nil, location: place.location)
            }
        }
        // Muting and quiet hours silence prompts, while an explicitly configured
        // shopping rule can still create its local draft.
        guard allowsPlacePrompts(for: id, at: now) else { return }
        defaults.set(now, forKey: key)
        if started, let rule {
            arrivalPlace = nil
            content.title = "Shopping trip ready at \(place.name)"
            content.body = "Cap: \(LKR.string(rule.cap)). Open Ledgerly to add items. No expense was recorded."
            content.userInfo = ["destination": "shoppingTrip"]
        } else {
            content.title = "At \(place.name)?"
            if rule != nil && !categoryAvailable {
                arrivalPlace = nil
                content.body = "Your shopping category is unavailable. Update the auto-start rule here."
                content.userInfo = ["destination": "places"]
            } else if hasExistingTrip {
                arrivalPlace = nil
                content.body = "A shopping trip is already active. Open Ledgerly to continue it."
                content.userInfo = ["destination": "shoppingTrip"]
            } else if let typical = PlaceSpendingPattern.analyze(entries: entries, place: place,
                                                                  asOf: now).typicalAmount {
                arrivalPlace = place
                content.body = "Typical recorded spend: \(LKR.string(typical)). Record only if you bought something."
                content.userInfo = ["destination": "placeExpense:\(id.uuidString)"]
            } else {
                arrivalPlace = place
                content.body = "Record an expense if you bought something here."
                content.userInfo = ["destination": "placeExpense:\(id.uuidString)"]
            }
        }
        content.sound = notificationSound(notificationPreferences.arrivalSound, for: .arrival)
        content.categoryIdentifier = "LEDGERLY_PLACE"
        content.threadIdentifier = "ledgerly.places"
        let isExpensePrompt = (content.userInfo["destination"] as? String)?.hasPrefix("placeExpense:") == true
        if isExpensePrompt {
            content.categoryIdentifier = "LEDGERLY_PLACE_EXPENSE"
            content.userInfo["arrivalOwner"] = owner
            content.userInfo["arrivalVisitID"] = visit.id.uuidString
            presentedArrivalVisitIDs.insert(visit.id)
            persistDismissedArrivals()
        }
        let request = UNNotificationRequest(identifier: "place.\(owner).\(id.uuidString).\(Int(now.timeIntervalSince1970))",
                                            content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        schedulePlaceNotification(request, for: id, arrivalVisitID: isExpensePrompt ? visit.id : nil)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let place = currentPlace(for: region) else { return }
        closeVisit(for: place.id, at: .now)
    }

    func reconcileOpenVisits() {
        abandonStaleVisits()
        guard visits.contains(where: \.isOpen), manager.authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 120 else { return }
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
            refreshArrivalCard()
            reconcile()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = "Could not check your current location. Check location access and try again."
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        if let region {
            pendingRegionIDs.remove(region.identifier)
            failedRegionIDs.insert(region.identifier)
            if let place = currentPlace(for: region) { monitoredIDs.remove(place.id) }
        }
        self.error = "Could not start reminders for this place. Check location access and retry."
    }

    private func reconcile() {
        updatePermissionMessage()
        let active = manager.authorizationStatus == .authorizedAlways ? allocatedPlaces : []
        let desiredIDs = Set(active.map { regionID(for: $0.id) })
        pendingRegionIDs.formIntersection(desiredIDs)
        failedRegionIDs.formIntersection(desiredIDs)
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
        monitoredIDs = Set(manager.monitoredRegions.compactMap { region in
            failedRegionIDs.contains(region.identifier) ? nil : currentPlace(for: region)?.id
        })
        for place in active {
            let identifier = regionID(for: place.id)
            if pendingRegionIDs.contains(identifier) || failedRegionIDs.contains(identifier) { continue }
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
            pendingRegionIDs.insert(identifier)
            manager.startMonitoring(for: region)
        }
    }

    private func stopLedgerlyRegions() {
        pendingRegionIDs.removeAll()
        failedRegionIDs.removeAll()
        monitoredIDs.removeAll()
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) {
            manager.stopMonitoring(for: region)
        }
    }

    func suspendForAccountDeletion(_ uid: String) {
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix + uid + ".") {
            manager.stopMonitoring(for: region)
        }
        guard owner == uid else { return }
        stopLedgerlyRegions()
        cancelPendingPlaceNotifications(includeDelivered: true)
        arrivalPlace = nil
        places = []
        entries = []
        enabledIDs = []
        visits = []
        pinnedIDs = []
        shoppingRules = [:]
        mutedIDs = []
        promptFeedback = [:]
    }

    private func updatePermissionMessage() {
        // The delegate refreshes this when app permission or device Location
        // Services changes; a blocking locationServicesEnabled() query is unnecessary.
        switch manager.authorizationStatus {
        case .authorizedAlways: permissionMessage = "Arrival monitoring available"
        case .authorizedWhenInUse: permissionMessage = "Allow Always location in device Settings for arrival alerts"
        case .denied, .restricted: permissionMessage = "Location access is off in device Settings"
        case .notDetermined: permissionMessage = "Enable a place to request location access"
        @unknown default: permissionMessage = "Location permission unavailable"
        }
    }

    private func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationStatus = status
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

    private func persistMuted() {
        defaults.set(mutedIDs.map(\.uuidString).sorted(), forKey: preferenceKey("muted"))
    }

    private func persistPromptFeedback() {
        if let data = try? JSONEncoder().encode(promptFeedback) {
            defaults.set(data, forKey: preferenceKey("promptFeedback"))
        }
    }

    private func isPlaceMuted(_ id: UUID) -> Bool {
        mutedIDs.contains(id) || (automaticMutingEnabled && promptFeedback[id]?.isAutomaticallyMuted == true)
    }

    private func persistDismissedArrivals() {
        let visitIDs = Set(visits.map(\.id))
        dismissedArrivalVisitIDs.formIntersection(visitIDs)
        presentedArrivalVisitIDs.formIntersection(visitIDs)
        defaults.set(dismissedArrivalVisitIDs.map(\.uuidString).sorted(),
                     forKey: preferenceKey("dismissedArrivals"))
        defaults.set(presentedArrivalVisitIDs.map(\.uuidString).sorted(),
                     forKey: preferenceKey("arrivalCardVisits"))
    }

    private func allowsPlacePrompts(for id: UUID, at date: Date) -> Bool {
        PlaceArrivalPolicy.allowsPrompts(isMuted: isPlaceMuted(id), quietHours: quietHours, now: date)
    }

    private func refreshArrivalCard() {
        let now = Date()
        arrivalPlace = visits.first(where: { visit in
            guard visit.isOpen, enabledIDs.contains(visit.placeID),
                  presentedArrivalVisitIDs.contains(visit.id),
                  !dismissedArrivalVisitIDs.contains(visit.id),
                  allowsPlacePrompts(for: visit.placeID, at: now),
                  let prompted = defaults.object(forKey: preferenceKey("prompt.\(visit.placeID.uuidString)")) as? Date,
                  prompted >= visit.enteredAt else { return false }
            return !entries.contains { entry in
                entry.kind == .expense && entry.location?.placeID == visit.placeID &&
                    entry.date >= visit.enteredAt && entry.date <= now
            }
        }).flatMap { visit in places.first { $0.id == visit.placeID } }
    }

    private func shouldDeliverPlaceNotification(for placeID: UUID, arrivalVisitID: UUID?, kind: PlaceAlertKind) -> Bool {
        enabledIDs.contains(placeID) && allowsPlacePrompts(for: placeID, at: .now.addingTimeInterval(1)) &&
            (kind != .departure || notificationPreferences.departureEnabled) &&
            (arrivalVisitID.map { !dismissedArrivalVisitIDs.contains($0) } ?? true)
    }

    private func schedulePlaceNotification(_ request: UNNotificationRequest, for placeID: UUID,
                                            arrivalVisitID: UUID? = nil, kind: PlaceAlertKind = .arrival) {
        let expectedOwner = owner
        Task { @MainActor [weak self] in
            guard let self, self.owner == expectedOwner,
                  self.shouldDeliverPlaceNotification(for: placeID, arrivalVisitID: arrivalVisitID, kind: kind) else { return }
            let center = UNUserNotificationCenter.current()
            // If this is the first enabled place, wait for the permission prompt
            // before scheduling an initial inside-state notification.
            await self.notificationAuthorizationTask?.value
            guard self.owner == expectedOwner,
                  self.shouldDeliverPlaceNotification(for: placeID, arrivalVisitID: arrivalVisitID, kind: kind) else { return }
            do {
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized ||
                      settings.authorizationStatus == .provisional ||
                      settings.authorizationStatus == .ephemeral else {
                    await self.refreshNotificationPermission()
                    return
                }
                guard self.owner == expectedOwner,
                      self.shouldDeliverPlaceNotification(for: placeID, arrivalVisitID: arrivalVisitID, kind: kind) else { return }
                try await center.add(request)
            } catch {
                if self.owner == expectedOwner {
                    self.error = "Could not send a place reminder. Check notification settings and try again."
                }
                return
            }
            if self.owner != expectedOwner ||
                !self.shouldDeliverPlaceNotification(for: placeID, arrivalVisitID: arrivalVisitID, kind: kind) {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            }
        }
    }

    private func cancelPendingPlaceNotifications(for placeID: UUID? = nil, includeDelivered: Bool = false) {
        let arrivalPrefix = "place.\(owner)." + (placeID.map { $0.uuidString + "." } ?? "")
        let departurePrefix = "departure.\(owner)."
        let testPrefix = "placeTest.\(owner)."
        let departureIDs = Set(visits.filter { placeID == nil || $0.placeID == placeID }
            .map { departurePrefix + $0.id.uuidString })
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let matches: (String) -> Bool = {
                $0.hasPrefix(arrivalPrefix) || departureIDs.contains($0) ||
                    (placeID == nil && ($0.hasPrefix(departurePrefix) || $0.hasPrefix(testPrefix)))
            }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter(matches))
            if includeDelivered {
                let delivered = await center.deliveredNotifications()
                center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }
                    .filter { $0.hasPrefix(arrivalPrefix) || (placeID == nil && $0.hasPrefix(testPrefix)) })
            }
        }
    }

    private func persistShoppingRules() {
        if let data = try? JSONEncoder().encode(shoppingRules) {
            defaults.set(data, forKey: preferenceKey("shoppingRules"))
        }
    }

    private var allocatedPlaces: [LedgerPlace] {
        PlaceArrivalPolicy.activePlaces(places, enabledIDs: enabledIDs,
                                        visits: visits, pinnedIDs: pinnedIDs)
    }

    private func persistVisits() {
        visits.sort { $0.enteredAt > $1.enteredAt }
        if visits.count > 500 { visits = Array(visits.prefix(500)) }
        persistDismissedArrivals()
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
        guard !abandoned && !reconciled && allowsPlacePrompts(for: id, at: date) else { return }
        guard let notice = PlaceDepartureNotice.make(for: visit, entries: entries,
            enabled: notificationPreferences.departureEnabled) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Left \(visit.placeName)"
        switch notice {
        case .recorded(let summary):
            content.body = "\(summary.count) \(summary.count == 1 ? "expense" : "expenses") · \(LKR.string(summary.total)) recorded."
            content.userInfo = ["destination": "transaction:\(summary.latestEntryID.uuidString)"]
        case .unrecorded:
            content.body = "Did you buy anything? Record an expense if you did. No purchase is assumed."
            content.userInfo = ["destination": "placeExpense:\(id.uuidString)"]
        }
        content.sound = notificationSound(notificationPreferences.departureSound, for: .departure)
        content.categoryIdentifier = "LEDGERLY_PLACE_DEPARTURE"
        content.threadIdentifier = "ledgerly.places"
        let request = UNNotificationRequest(identifier: "departure.\(owner).\(visit.id.uuidString)",
                                            content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        schedulePlaceNotification(request, for: id, kind: .departure)
    }
}
