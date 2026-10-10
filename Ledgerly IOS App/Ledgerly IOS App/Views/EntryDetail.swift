import SwiftUI
import MapKit

struct EntryDetail: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let entry: LedgerEntry
    @State private var editing = false
    @State private var deleting = false
    private var current: LedgerEntry { store.entries.first { $0.id == entry.id } ?? entry }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LedgerIconTile(icon: .category(current.category, kind: current.kind), size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.displayTitle).font(.headline)
                        Text(current.category).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                LabeledContent("Amount", value: LKR.string(current.amount))
                LabeledContent("Type", value: current.kind.label)
                LabeledContent("Category", value: current.category)
                if let method = store.paymentMethods.first(where: { $0.id == current.paymentMethodID }) {
                    LabeledContent("Payment method", value: method.name)
                }
                LabeledContent("Date", value: current.date.formatted(date: .long, time: .omitted))
                if !current.note.isEmpty { LabeledContent("Note", value: current.note) }
                if let location = current.location {
                    LabeledContent("Recorded place", value: location.name)
                }
            }
            if let location = current.location {
                Section("Location") {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: location.latitude,
                                                       longitude: location.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))),
                        interactionModes: []) {
                        Marker(location.name, coordinate: CLLocationCoordinate2D(
                            latitude: location.latitude, longitude: location.longitude))
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                }
            }
            if let receipt = ReceiptImageStore.image(for: entry.id) {
                Section("Receipt on this iPhone") {
                    Image(uiImage: receipt).resizable().scaledToFit()
                        .accessibilityLabel("Receipt attached to this transaction")
                }
            }
            Button("Delete transaction", role: .destructive) { deleting = true }
        }
        .navigationTitle(current.displayTitle)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { EntryEditor(store: store, initialKind: current.kind, editing: current) }
        .confirmationDialog("Delete this transaction?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { store.delete(entry); dismiss() }
        }
    }
}
