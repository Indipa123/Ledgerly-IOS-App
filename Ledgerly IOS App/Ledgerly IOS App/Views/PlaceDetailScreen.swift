import SwiftUI
import MapKit

struct PlaceDetailScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var monitor: PlaceArrivalMonitor
    let placeID: UUID
    let recordExpense: (LedgerPlace) -> Void
    let edit: (LedgerPlace) -> Void
    let enableArrival: (LedgerPlace) -> Void
    let configureShopping: (LedgerPlace) -> Void
    let remove: (LedgerPlace) -> Void

    private var place: LedgerPlace? { store.places.first { $0.id == placeID } }

    var body: some View {
        Group {
            if let place {
                detail(place)
            } else {
                ContentUnavailableView("Place unavailable", systemImage: "mappin.slash",
                    description: Text("This place is no longer saved in your ledger."))
            }
        }
        .navigationTitle(place?.name ?? "Place")
        .toolbar {
            if let place { Button("Edit place") { edit(place) } }
        }
    }

    private func detail(_ place: LedgerPlace) -> some View {
        let expenses = PlaceCalculations.expenses(at: place, in: store.entries)
        let total = expenses.reduce(Decimal.zero) { $0 + $1.amount }
        return Form {
            Section {
                Label(place.name, systemImage: "mappin.and.ellipse").font(.headline)
                LabeledContent("Recorded spending", value: LKR.string(total))
                LabeledContent("Expenses", value: "\(expenses.count)")
                Button("Record expense here", systemImage: "plus.circle") { recordExpense(place) }
            }
            Section("Location") {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))) {
                    Marker(place.name, coordinate: CLLocationCoordinate2D(
                        latitude: place.latitude, longitude: place.longitude))
                        .tint(Palette.cranberry)
                    if monitor.isEnabled(place) {
                        MapCircle(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                            radius: monitor.radius(for: place))
                            .foregroundStyle(Palette.plum.opacity(0.13))
                    }
                }
                .id(place)
                .frame(height: 280)
                .listRowInsets(EdgeInsets())
                Text("Only expenses saved with this place are included.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Arrival reminders") {
                PlaceArrivalControls(place: place, monitor: monitor,
                    enableArrival: enableArrival, configureShopping: configureShopping)
                NavigationLink {
                    PlacePromptSettingsScreen(monitor: monitor)
                } label: {
                    Label("Arrival and departure sounds", systemImage: "bell.badge")
                }
            }
            Section("Recorded expenses") {
                if expenses.isEmpty {
                    Text("No expenses recorded here yet.").foregroundStyle(.secondary)
                }
                ForEach(expenses) { entry in
                    NavigationLink { EntryDetail(store: store, entry: entry) } label: {
                        EntryRow(entry: entry)
                    }
                }
            }
            Section {
                Button("Remove saved place", role: .destructive) { remove(place) }
            }
        }
    }
}
