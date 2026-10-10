import SwiftUI
import MapKit

struct PlacesScreen: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: LedgerStore
    @ObservedObject var monitor: PlaceArrivalMonitor
    let recordExpense: (LedgerPlace) -> Void
    @State private var adding = false
    @State private var editing: LedgerPlace?
    @State private var enablingArrivalFor: LedgerPlace?
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 7.8731, longitude: 80.7718),
        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)))

    private var points: [SpendingMapPoint] {
        PlaceCalculations.mapPoints(places: store.places, entries: store.entries)
    }

    var body: some View {
        List {
            if let arrived = monitor.arrivalPlace {
                Section("Nearby saved place") {
                    Text("At \(arrived.name)? Record an expense only if you bought something.")
                    HStack {
                        Button("Record expense") { recordExpense(arrived) }
                        Spacer()
                        Button("Dismiss") { monitor.dismissArrival() }
                    }
                }
            }
            Section {
                Map(position: $position) {
                    ForEach(store.places.filter { monitor.isEnabled($0) }) { place in
                        MapCircle(center: CLLocationCoordinate2D(latitude: place.latitude,
                                                                  longitude: place.longitude),
                                  radius: monitor.radius(for: place))
                            .foregroundStyle(Palette.plum.opacity(0.13))
                    }
                    ForEach(points) { point in
                        Marker(point.name,
                               coordinate: CLLocationCoordinate2D(latitude: point.latitude,
                                                                  longitude: point.longitude))
                            .tint(point.count > 0 ? Palette.cranberry : Palette.plum)
                    }
                }
                .frame(height: 300)
                .listRowInsets(EdgeInsets())
                Text("A location never proves a purchase. Only expenses you attached to a place count as spending here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Saved places") {
                if store.places.isEmpty {
                    Text("No saved places yet. Add one with the + button or while entering an expense.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.places) { place in
                    VStack(alignment: .leading, spacing: 8) {
                    Button { editing = place } label: {
                        HStack(spacing: 12) {
                        LedgerIconTile(icon: .init(symbol: "mappin.and.ellipse", color: Palette.iconPlum), size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.name).font(.headline)
                            if let point = points.first(where: { $0.id == place.id.uuidString }), point.count > 0 {
                                Text("\(point.count) \(point.count == 1 ? "expense" : "expenses") · \(LKR.string(point.amount))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text("No recorded expenses").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        }
                    }
                    .buttonStyle(.plain)
                    Toggle("Arrival reminder", isOn: Binding(
                        get: { monitor.isEnabled(place) },
                        set: { enabled in
                            if enabled { enablingArrivalFor = place }
                            else { monitor.setEnabled(false, for: place) }
                        }))
                    if monitor.isEnabled(place) {
                        Text(monitor.isActive(place) ? "Monitoring arrival" : "Watching paused · \(monitor.pausedReason(for: place))")
                            .font(.footnote)
                            .foregroundStyle(monitor.isActive(place) ? .green : .secondary)
                        Toggle("Prioritize this place", isOn: Binding(
                            get: { monitor.isPinned(place) },
                            set: { monitor.setPinned($0, for: place) }))
                        Picker("Arrival radius", selection: Binding(
                            get: { Int(monitor.radius(for: place)) },
                            set: { monitor.setRadius(Double($0), for: place) })) {
                            ForEach([50, 100, 150, 250, 500], id: \.self) { meters in
                                Text("\(meters) m").tag(meters)
                            }
                        }
                        if monitor.hasReducedAccuracyWarning(for: place) {
                            Text("Precise Location is off. A small radius may miss arrivals.")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            monitor.setEnabled(false, for: place)
                            store.deletePlace(place)
                        }
                    }
                }
            }
            Section("Arrival reminders") {
                Text("Monitoring \(monitor.monitoredCount) of \(PlaceArrivalPolicy.maximumRegions) places")
                    .font(.headline)
                Text("Optional. Ledgerly asks for Always location when you enable a place. An arrival can suggest recording an expense; it never creates one automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(monitor.permissionMessage).font(.footnote).foregroundStyle(.secondary)
                Text(monitor.notificationMessage).font(.footnote).foregroundStyle(.secondary)
                if monitor.needsSettings {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                if monitor.enabledIDs.count > PlaceArrivalPolicy.maximumRegions {
                    Text("The most visited, recent, or prioritized places hold the 20 slots. Paused places are marked above.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let error = monitor.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            if !monitor.visits.isEmpty {
                Section("Recent visits") {
                    ForEach(monitor.visits.prefix(20)) { visit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(visit.placeName).font(.headline)
                            Text(visit.enteredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if visit.isOpen {
                                Text("Inside · no purchase assumed")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text(visit.isAbandoned ? "Visit closed after 12 hours (missed departure)" :
                                     visit.isReconciled ? "Departure estimated after reopening the app" :
                                     "Departed · \(visitExpenseSummary(visit))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if points.contains(where: { $0.count > 0 }) {
                Section("Recorded spending locations") {
                    ForEach(points.filter { $0.count > 0 }) { point in
                        LabeledContent(point.name,
                                       value: "\(LKR.string(point.amount)) · \(point.count) recorded")
                    }
                }
            }
        }
        .navigationTitle("Places")
        .toolbar { Button("Add place", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { PlaceEditor(store: store) }
        .sheet(item: $editing) { PlaceEditor(store: store, editing: $0) }
        .alert("Enable arrival reminders?", isPresented: Binding(
            get: { enablingArrivalFor != nil },
            set: { if !$0 { enablingArrivalFor = nil } })) {
                Button("Enable") {
                    if let place = enablingArrivalFor { monitor.setEnabled(true, for: place) }
                    enablingArrivalFor = nil
                }
                Button("Cancel", role: .cancel) { enablingArrivalFor = nil }
            } message: {
                Text("Ledgerly will request Always location and notification permission to remind you when you arrive near this saved place. You can turn it off here anytime.")
            }
        .onAppear { framePoints() }
        .onChange(of: points.map { "\($0.id):\($0.latitude):\($0.longitude):\($0.amount)" }) { _, _ in
            framePoints()
        }
    }

    private func framePoints() {
        guard let first = points.first else { return }
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLat = latitudes.min() ?? first.latitude
        let maxLat = latitudes.max() ?? first.latitude
        let minLon = longitudes.min() ?? first.longitude
        let maxLon = longitudes.max() ?? first.longitude
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.4),
                                   longitudeDelta: max(0.02, (maxLon - minLon) * 1.4))))
    }

    private func visitExpenseSummary(_ visit: PlaceVisit) -> String {
        let recorded = store.entries.filter { entry in
            entry.kind == .expense && entry.location?.placeID == visit.placeID &&
            entry.date >= visit.enteredAt && entry.date <= (visit.exitedAt ?? .now)
        }
        let total = recorded.reduce(Decimal.zero) { $0 + $1.amount }
        return recorded.isEmpty ? "no expenses recorded" :
            "\(recorded.count) \(recorded.count == 1 ? "expense" : "expenses"), \(LKR.string(total))"
    }
}
