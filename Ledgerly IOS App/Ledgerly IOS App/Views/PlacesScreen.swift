import SwiftUI
import MapKit

struct PlacesScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: LedgerStore
    @ObservedObject var monitor: PlaceArrivalMonitor
    let recordExpense: (LedgerPlace) -> Void
    var allowsColumns = false
    @State private var adding = false
    @State private var editing: LedgerPlace?
    @State private var enablingArrivalFor: LedgerPlace?
    @State private var configuringShopping: LedgerPlace?
    @State private var removing: LedgerPlace?
    @State private var selectedPlaceID: UUID?
    @State private var search = ""
    @State private var selectedMapPointID: String?
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 7.8731, longitude: 80.7718),
        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)))

    private var points: [SpendingMapPoint] {
        PlaceCalculations.mapPoints(places: store.places, entries: store.entries)
    }

    private var visiblePlaces: [LedgerPlace] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.places.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            let usesColumns = allowsColumns && geometry.size.width >= 860 &&
                !dynamicTypeSize.isAccessibilitySize
            Group {
                if usesColumns {
                    HStack(spacing: 0) {
                        NavigationStack { placeList(usesColumns: true) }
                            .frame(width: min(420, max(340, geometry.size.width * 0.38)))
                        Divider()
                        NavigationStack {
                            if let selectedPlaceID {
                                placeDetail(id: selectedPlaceID)
                                    .id(selectedPlaceID)
                            } else {
                                Form {
                                    Section {
                                        ContentUnavailableView("Select a place", systemImage: "mappin.and.ellipse",
                                            description: Text("Choose a saved place from the list or map to see its spending and arrival settings."))
                                    }
                                    overviewMap
                                }
                                .navigationTitle("Places map")
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    NavigationStack(path: Binding(
                        get: { selectedPlaceID.map { [$0] } ?? [] },
                        set: { selectedPlaceID = $0.last })) {
                        placeList(usesColumns: false)
                            .navigationDestination(for: UUID.self) { id in placeDetail(id: id) }
                    }
                }
            }
        }
        .sheet(isPresented: $adding) {
            PlaceEditor(store: store, onSaved: { search = ""; select($0.id) })
        }
        .sheet(item: $editing) { PlaceEditor(store: store, editing: $0) }
        .sheet(item: $configuringShopping) { place in
            NavigationStack { ShoppingArrivalRuleEditor(place: place, store: store, monitor: monitor) }
        }
        .alert("Enable arrival reminders?", isPresented: Binding(
            get: { enablingArrivalFor != nil },
            set: { if !$0 { enablingArrivalFor = nil } })) {
                Button("Enable") {
                    if let place = enablingArrivalFor, store.places.contains(where: { $0.id == place.id }) {
                        monitor.setEnabled(true, for: place)
                    }
                    enablingArrivalFor = nil
                }
                Button("Cancel", role: .cancel) { enablingArrivalFor = nil }
            } message: {
                Text("Ledgerly will request Always location and notification permission to remind you when you arrive near this saved place. You can turn it off here anytime.")
            }
        .confirmationDialog("Remove this saved place?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove saved place", role: .destructive) {
                    if let place = removing {
                        store.deletePlace(place)
                        if !store.places.contains(where: { $0.id == place.id }) {
                            monitor.setEnabled(false, for: place)
                        }
                    }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("Your recorded transactions keep their original locations. Arrival reminders for this place will stop.")
            }
        .onAppear { framePoints() }
        .onChange(of: points.map { "\($0.id):\($0.latitude):\($0.longitude)" }) { _, _ in framePoints() }
        .onChange(of: selectedPlaceID) { _, id in
            if id == nil { selectedMapPointID = nil }
        }
        .onChange(of: selectedMapPointID) { _, value in
            if let value, let id = UUID(uuidString: value),
               store.places.contains(where: { $0.id == id }) {
                search = ""
                select(id)
            }
        }
        .onChange(of: visiblePlaces.map(\.id)) { _, ids in
            if let selectedPlaceID, !ids.contains(selectedPlaceID) { clearSelection() }
        }
        .onChange(of: store.places.map(\.id)) { _, ids in
            if let id = editing?.id, !ids.contains(id) { editing = nil }
            if let id = configuringShopping?.id, !ids.contains(id) { configuringShopping = nil }
            if let id = enablingArrivalFor?.id, !ids.contains(id) { enablingArrivalFor = nil }
            if let id = removing?.id, !ids.contains(id) { removing = nil }
        }
    }

    private func select(_ id: UUID) {
        selectedPlaceID = id
    }

    private func clearSelection() {
        selectedPlaceID = nil
        selectedMapPointID = nil
    }

    private func placeDetail(id: UUID) -> some View {
        PlaceDetailScreen(store: store, monitor: monitor, placeID: id,
            recordExpense: recordExpense, edit: { editing = $0 },
            enableArrival: { enablingArrivalFor = $0 },
            configureShopping: { configuringShopping = $0 }, remove: { removing = $0 })
    }

    private func placeList(usesColumns: Bool) -> some View {
        List {
            if let arrived = monitor.arrivalPlace {
                TimelineView(.everyMinute) { timeline in
                    if !monitor.isMuted(arrived) && !monitor.quietHours.contains(timeline.date) {
                        Section("Nearby saved place") {
                            Text("At \(arrived.name)? Record an expense only if you bought something.")
                            if let typical = store.spendingPattern(for: arrived).typicalAmount {
                                Text("Typical recorded spend here: \(LKR.string(typical))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Button("Record expense") { recordExpense(arrived) }
                            Button("Dismiss") { monitor.dismissArrival(explicitlyDismissed: true) }
                        }
                    }
                }
            }
            if !usesColumns { overviewMap }
            Section("Saved places") {
                if visiblePlaces.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No saved places" : "No matching places",
                        systemImage: "mappin.slash",
                        description: Text(search.isEmpty ? "Add a place to keep its map, spending and arrival settings together." : "Try another name or clear your search."))
                }
                ForEach(visiblePlaces) { place in
                    Button { select(place.id) } label: {
                        HStack {
                            placeRow(place)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("saved-place-\(place.id.uuidString)")
                    .accessibilityAddTraits(selectedPlaceID == place.id ? .isSelected : [])
                    .listRowBackground(usesColumns && selectedPlaceID == place.id ? Palette.cranberry.opacity(0.12) : Palette.card)
                    .swipeActions {
                        Button("Remove", role: .destructive) { removing = place }
                    }
                }
            }
            arrivalSummary
            historySections
        }
        .scrollContentBackground(.hidden)
        .background(Palette.cream.ignoresSafeArea())
        .searchable(text: $search, prompt: "Search saved places")
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(usesColumns ? .inline : .large)
        .toolbar(.visible, for: .navigationBar)
        .modifier(PlacesNavigationBackground())
        .toolbar { Button("Add place", systemImage: "plus") { adding = true } }
    }

    private func placeRow(_ place: LedgerPlace) -> some View {
        HStack(spacing: 12) {
            LedgerIconTile(icon: .init(symbol: "mappin.and.ellipse", color: Palette.iconPlum), size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name).font(.headline).foregroundStyle(Palette.ink)
                if let point = points.first(where: { $0.id == place.id.uuidString }), point.count > 0 {
                    Text("\(point.count) \(point.count == 1 ? "expense" : "expenses") · \(LKR.string(point.amount))")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("No recorded expenses").font(.subheadline).foregroundStyle(.secondary)
                }
                if monitor.isEnabled(place) {
                    Text(monitor.status(for: place))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 54)
        .accessibilityElement(children: .combine)
    }

    private var overviewMap: some View {
        Section {
            Map(position: $position, selection: $selectedMapPointID) {
                ForEach(store.places.filter { monitor.isEnabled($0) }) { place in
                    MapCircle(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                              radius: monitor.radius(for: place))
                        .foregroundStyle(Palette.plum.opacity(0.13))
                }
                ForEach(points) { point in
                    Marker(point.name, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                        .tint(point.count > 0 ? Palette.cranberry : Palette.plum)
                        .tag(point.id)
                }
            }
            .frame(height: allowsColumns ? 360 : 300)
            .listRowInsets(EdgeInsets())
            Text("Spending includes only expenses saved with this place.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var arrivalSummary: some View {
        Section("Arrival and departure reminders") {
            NavigationLink {
                PlacePromptSettingsScreen(monitor: monitor)
            } label: {
                Label("Place notifications and sounds", systemImage: "bell.badge")
            }
            Text(monitor.notificationPreferences.departureEnabled ? "Departure reminders on" : "Departure reminders off")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Monitoring \(monitor.monitoredCount) of \(PlaceArrivalPolicy.maximumRegions) places")
                .font(.headline)
            Text("Get reminders at saved places. Enable a place to allow background location access.")
                .font(.footnote).foregroundStyle(.secondary)
            Text(monitor.permissionMessage).font(.footnote).foregroundStyle(.secondary)
            Text(monitor.notificationMessage).font(.footnote).foregroundStyle(.secondary)
            Button("Check arrival monitoring", systemImage: "arrow.clockwise") {
                Task { await monitor.refreshPermissions() }
            }
            if monitor.needsSettings {
                Button("Open device Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            if monitor.enabledIDs.count > PlaceArrivalPolicy.maximumRegions {
                Text("Up to 20 places can be monitored. Prioritise a place to keep its reminders active.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let error = monitor.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var historySections: some View {
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

struct PlaceArrivalControls: View {
    @Environment(\.openURL) private var openURL
    let place: LedgerPlace
    @ObservedObject var monitor: PlaceArrivalMonitor
    let enableArrival: (LedgerPlace) -> Void
    let configureShopping: (LedgerPlace) -> Void

    var body: some View {
        Group {
            Toggle("Arrival reminder", isOn: Binding(
                get: { monitor.isEnabled(place) },
                set: { enabled in
                    if enabled { enableArrival(place) }
                    else { monitor.setEnabled(false, for: place) }
                }))
            if monitor.isEnabled(place) {
                Text(monitor.status(for: place))
                    .font(.footnote)
                    .foregroundStyle(monitor.isActive(place) ? .green : .secondary)
                Text(monitor.permissionMessage).font(.footnote).foregroundStyle(.secondary)
                Text(monitor.notificationMessage).font(.footnote).foregroundStyle(.secondary)
                if monitor.needsSettings {
                    Button("Open device Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Button("Check arrival monitoring", systemImage: "arrow.clockwise") {
                    Task { await monitor.refreshPermissions() }
                }
                if let error = monitor.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Toggle("Mute place alerts", isOn: Binding(
                    get: { monitor.isMuted(place) },
                    set: { monitor.setMuted($0, for: place) }))
                if monitor.isMuted(place) {
                    Text(monitor.isAutomaticallyMuted(place)
                        ? "Automatically muted after three dismissed visits. Visit history and configured shopping trips continue."
                        : "Arrival cards and place notifications are muted. Visit history and configured shopping trips continue.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if monitor.isAutomaticallyMuted(place) {
                        Button("Resume alerts") { monitor.setMuted(false, for: place) }
                    }
                } else if monitor.dismissalStreak(for: place) > 0 {
                    Text("\(monitor.dismissalStreak(for: place)) of \(PlacePromptDismissalState.threshold) dismissed visits before automatic mute.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
                Button {
                    configureShopping(place)
                } label: {
                    Label(monitor.shoppingRule(for: place) == nil ? "Set up shopping on arrival" :
                          "Edit shopping on arrival", systemImage: "basket")
                }
                if let rule = monitor.shoppingRule(for: place) {
                    Text("Starts an empty shopping trip with a \(LKR.string(rule.cap)) cap when arrival is detected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ShoppingArrivalRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let place: LedgerPlace
    @ObservedObject var store: LedgerStore
    @ObservedObject var monitor: PlaceArrivalMonitor
    @State private var capText: String
    @State private var categoryID: UUID?

    init(place: LedgerPlace, store: LedgerStore, monitor: PlaceArrivalMonitor) {
        self.place = place
        self.store = store
        self.monitor = monitor
        let rule = monitor.shoppingRule(for: place)
        _capText = State(initialValue: rule.map { NSDecimalNumber(decimal: $0.cap).stringValue } ?? "")
        _categoryID = State(initialValue: rule?.categoryID ??
            store.activeCategories(for: .expense).first(where: { $0.name == "Groceries" })?.id ??
            store.activeCategories(for: .expense).first?.id)
    }

    private var cap: Decimal? {
        guard let amount = Decimal(string: capText.replacingOccurrences(of: ",", with: ".")),
              amount > 0 else { return nil }
        return amount
    }

    private var categories: [LedgerCategory] { store.activeCategories(for: .expense) }
    private var categoryAvailable: Bool { categories.contains { $0.id == categoryID } }

    var body: some View {
        Form {
            Section {
                TextField("Spending cap in LKR", text: $capText)
                    .keyboardType(.decimalPad)
                Picker("Expense category", selection: $categoryID) {
                    Text("Choose a category").tag(Optional<UUID>.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                if categoryID != nil && !categoryAvailable {
                    Text("This category is archived. Choose an active expense category.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("At \(place.name)")
            } footer: {
                Text("When Ledgerly detects an arrival, it starts one empty trip with this cap. Existing trips are kept. Add items and finish the trip to save an expense at this place.")
            }
            Section {
                Button("Save automatic start") {
                    guard let cap, let categoryID else { return }
                    monitor.setShoppingRule(.init(cap: cap, categoryID: categoryID), for: place)
                    dismiss()
                }
                .disabled(cap == nil || !categoryAvailable)
                if monitor.shoppingRule(for: place) != nil {
                    Button("Turn off automatic start", role: .destructive) {
                        monitor.setShoppingRule(nil, for: place)
                        dismiss()
                    }
                }
            }
            Section {
                Text("Arrival detection requires Always location. iOS may deliver it late or miss it. A Live Activity can start after you open Ledgerly; no expense is created until you finish the trip.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shopping on arrival")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}

private struct PlacesNavigationBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .toolbarBackground(Palette.cream, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
