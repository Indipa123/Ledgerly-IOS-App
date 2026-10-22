import SwiftUI
import MapKit

struct EntryDetail: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let entry: LedgerEntry
    @State private var editing = false
    @State private var deleting = false
    @State private var splitting = false
    private var current: LedgerEntry? { store.entries.first { $0.id == entry.id } }
    var body: some View {
        Group {
            if let current {
                detailForm(current)
            } else {
                ContentUnavailableView("Transaction unavailable", systemImage: "tray",
                    description: Text("This transaction is no longer in your ledger."))
            }
        }
        .navigationTitle(current?.displayTitle ?? "Transaction")
        .toolbar {
            if current != nil && !belongsToCompletedEvent { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing) {
            if let current { EntryEditor(store: store, initialKind: current.kind, editing: current) }
        }
        .sheet(isPresented: $splitting) {
            if let current {
                NavigationStack { SplitEditor(store: store, initialEntryID: current.id) }
            }
        }
        .confirmationDialog("Delete this transaction?", isPresented: $deleting) {
            Button("Delete", role: .destructive) {
                guard let current else { return }
                store.delete(current)
                // A protected split/event or failed save should leave the detail open.
                if !store.entries.contains(where: { $0.id == current.id }) { dismiss() }
            }
        }
        .onChange(of: current == nil) { _, unavailable in
            if unavailable { editing = false; splitting = false; deleting = false }
        }
    }

    private func detailForm(_ current: LedgerEntry) -> some View {
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
                if let event = store.lifeEvents.first(where: { $0.id == current.eventID }) {
                    LabeledContent("Event budget", value: event.name)
                }
                if let reason = current.budgetOverrideReason, !reason.isEmpty {
                    LabeledContent("Over-budget reason", value: reason)
                }
            }
            Section {
                DisclosureGroup("Category suggestion details") {
                    if let suggestion = current.categorySuggestion {
                        LabeledContent("Source", value: suggestion.source?.label ?? "No reliable suggestion")
                        if let name = suggestion.suggestedCategoryName {
                            LabeledContent("Suggested category", value: name)
                        }
                        LabeledContent("Category saved", value: suggestion.savedCategoryName)
                        if let alternatives = suggestion.alternatives, !alternatives.isEmpty {
                            LabeledContent("Options shown", value: alternatives.map(\.name).joined(separator: ", "))
                        }
                        LabeledContent("Your choice", value: suggestion.wasAccepted.map {
                            $0 ? "Kept suggestion" : "Chose another category"
                        } ?? "Selected manually")
                        LabeledContent("Recorded", value: suggestion.recordedAt.formatted(date: .abbreviated,
                                                                                         time: .shortened))
                        if suggestion.categoryChanged(categoryID: current.categoryID, kind: current.kind.rawValue) {
                            Label("The category or transaction type changed after this record was saved.",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        if let review = suggestion.review,
                           review.matches(categoryID: current.categoryID, kind: current.kind.rawValue, title: current.title) {
                            LabeledContent("Category reviewed", value: review.reviewedAt.formatted(
                                date: .abbreviated, time: .shortened))
                        }
                    } else {
                        Text("No suggestion record was saved for this transaction.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Saved with the original transaction on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let history = current.categorySuggestion?.predictionHistory, !history.events.isEmpty {
                predictionHistorySection(history)
            }
            if !current.categoryChanges.isEmpty {
                Section {
                    ForEach(current.categoryChanges.reversed()) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("From", value: categoryLabel(change.from))
                            LabeledContent("To", value: categoryLabel(change.to))
                            Text(change.origin.label).font(.subheadline.weight(.medium))
                            Text(change.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Category history")
                } footer: {
                    Text("Category changes recorded by this device.")
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
                    .id(current.location)
                    .listRowInsets(EdgeInsets())
                }
            }
            let receiptPages = ReceiptImageStore.pages(for: entry.id)
            if !receiptPages.isEmpty {
                Section("Receipt (\(receiptPages.count) pages)") {
                    ForEach(Array(receiptPages.enumerated()), id: \.offset) { index, data in
                        if let receipt = UIImage(data: data) {
                            Image(uiImage: receipt).resizable().scaledToFit()
                                .accessibilityLabel("Receipt page \(index + 1)")
                        }
                    }
                }
            }
            if current.kind == .expense {
                Section("Shared expense") {
                    if let bill = store.splitBills.first(where: { $0.entryID == current.id }) {
                        NavigationLink { SplitDetail(store: store, billID: bill.id) } label: {
                            LabeledContent("Split with friends", value: "\(LKR.string(bill.outstanding)) owed")
                        }
                    } else {
                        Button("Split with friends") { splitting = true }
                    }
                }
            }
            if !belongsToCompletedEvent && !hasSplit {
                Button("Delete transaction", role: .destructive) { deleting = true }
            } else if hasSplit {
                Text("Remove the split before deleting this expense.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func predictionHistorySection(_ history: CategoryPredictionHistory) -> some View {
        Section {
            DisclosureGroup("Suggestion changes (\(history.events.count))") {
                ForEach(history.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.outcome.suggestedCategoryName ?? "No reliable suggestion")
                            .font(.headline)
                        Text("\(EntryKind(rawValue: event.outcome.kind)?.label ?? "Transaction") · \(event.outcome.source?.label ?? "Choose a category")")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !event.outcome.alternatives.isEmpty {
                            Text("Options: \(event.outcome.alternatives.map(\.name).joined(separator: ", "))")
                                .font(.subheadline)
                        }
                        Text(event.recordedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if history.omittedCount > 0 {
                    Text("Earlier changes omitted: \(history.omittedCount)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Recent suggestions from when you first entered this transaction. Kept on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var belongsToCompletedEvent: Bool {
        guard let current else { return false }
        return store.lifeEvents.contains { $0.id == current.eventID && $0.completedAt != nil }
    }

    private func categoryLabel(_ selection: CategorySelection) -> String {
        let kind = EntryKind(rawValue: selection.kind)?.label ?? "Previous type"
        return "\(selection.name) · \(kind)"
    }

    private var hasSplit: Bool {
        guard let current else { return false }
        return store.splitBills.contains { $0.entryID == current.id }
    }
}
