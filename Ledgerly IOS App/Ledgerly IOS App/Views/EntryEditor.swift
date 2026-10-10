import SwiftUI
import PhotosUI
import VisionKit
import AVFoundation
import Combine

private struct ReceiptCapture: Identifiable {
    let id = UUID()
    let imageData: Data?
}

struct EntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: LedgerStore
    @StateObject private var currentLocation = CurrentLocationService()
    let initialKind: EntryKind
    var initialPlaceID: UUID? = nil
    var editing: LedgerEntry? = nil
    @State private var kind: EntryKind
    @State private var amount = ""
    @State private var title = ""
    @State private var categoryID: UUID?
    @State private var categoryChosenByUser = false
    @State private var paymentMethodID: UUID?
    @State private var selectedPlaceID: UUID?
    @State private var unlistedLocation: LedgerLocation?
    @State private var showingPlaceEditor = false
    @State private var date = Date()
    @State private var note = ""
    @State private var discard = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var receiptCapture: ReceiptCapture?
    @State private var receiptData: Data?
    @State private var existingReceipt: UIImage?
    @State private var receiptError: String?

    init(store: LedgerStore, initialKind: EntryKind, editing: LedgerEntry? = nil,
         initialPlaceID: UUID? = nil) {
        self.store = store
        self.initialKind = initialKind
        self.editing = editing
        self.initialPlaceID = initialPlaceID
        _kind = State(initialValue: editing?.kind ?? initialKind)
        _selectedPlaceID = State(initialValue: editing?.location?.placeID ?? initialPlaceID)
    }

    private var rememberedCategory: (category: LedgerCategory, examples: Int, match: CategoryMatch)? {
        guard editing == nil,
              let suggestion = store.suggestedCategory(for: kind, title: title),
              let category = store.activeCategories(for: kind).first(where: { $0.id == suggestion.categoryID })
        else { return nil }
        return (category, suggestion.exampleCount, suggestion.match)
    }

    private var value: Decimal? {
        guard let parsed = Decimal(string: amount.replacingOccurrences(of: ",", with: ".")), parsed > 0 else { return nil }
        return parsed
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Amount in LKR", text: $amount).keyboardType(.decimalPad)
                TextField(kind == .expense ? "Merchant or description (optional)" : "Source or description (optional)", text: $title)
                Picker("Category", selection: Binding(
                    get: { categoryID },
                    set: { categoryID = $0; categoryChosenByUser = true })) {
                    Text("Choose a category").tag(Optional<UUID>.none)
                    ForEach(store.activeCategories(for: kind)) { category in
                        Label(category.name,
                              systemImage: LedgerIconDescriptor.category(category.name, kind: category.kind).symbol)
                            .tag(Optional(category.id))
                    }
                }
                if let rememberedCategory {
                    HStack {
                        Label(rememberedCategory.match == .exact
                              ? "Remembered: \(rememberedCategory.category.name)"
                              : "Suggested: \(rememberedCategory.category.name)",
                              systemImage: "sparkle.magnifyingglass")
                        Spacer()
                        if categoryID == rememberedCategory.category.id && categoryChosenByUser {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(categoryID == rememberedCategory.category.id ? "Confirm" : "Use") {
                                categoryID = rememberedCategory.category.id
                                categoryChosenByUser = true
                            }
                        }
                    }
                    Text(rememberedCategory.match == .exact
                         ? "Based on \(rememberedCategory.examples) previous \(rememberedCategory.examples == 1 ? "transaction" : "transactions") with this name. Confirm the category before saving."
                         : "This looks similar to a previous description. Check the category before saving; your choice improves later suggestions.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if editing == nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No reliable category match yet. Choose one and Ledgerly will remember it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Payment method", selection: $paymentMethodID) {
                    Text("Not specified").tag(Optional<UUID>.none)
                    ForEach(store.activePaymentMethods) { method in
                        Label(method.name, systemImage: LedgerIconDescriptor.payment(method.kind).symbol)
                            .tag(Optional(method.id))
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...4)
                Section("Place (optional)") {
                    Picker("Recorded at", selection: Binding(
                        get: { selectedPlaceID },
                        set: { selectedPlaceID = $0; unlistedLocation = nil })) {
                        Text("No place").tag(Optional<UUID>.none)
                        ForEach(store.places) { place in
                            Text(place.name).tag(Optional(place.id))
                        }
                        if let existing = editing?.location,
                           let id = existing.placeID,
                           !store.places.contains(where: { $0.id == id }) {
                            Text("\(existing.name) (previously saved)").tag(Optional(id))
                        }
                    }
                    Button {
                        currentLocation.locate()
                    } label: {
                        Label("Use Current Location", systemImage: "location.fill")
                    }
                    .disabled(currentLocation.isLocating)
                    if currentLocation.isLocating { ProgressView("Finding your location…") }
                    if let error = currentLocation.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let location = unlistedLocation {
                        TextField("Location name", text: Binding(
                            get: { unlistedLocation?.name ?? "" },
                            set: { unlistedLocation?.name = $0 }))
                        Text("\(location.latitude.formatted(.number.precision(.fractionLength(6)))), \(location.longitude.formatted(.number.precision(.fractionLength(6))))")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Remove location", role: .destructive) { unlistedLocation = nil }
                    }
                    Button("Save a new place") { showingPlaceEditor = true }
                    Text("Only expenses count toward spending totals on the Places map.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .expense {
                    Section("Receipt") {
                        if let image = receiptData.flatMap(UIImage.init(data:)) ?? existingReceipt {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                                .accessibilityLabel("Attached receipt")
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Choose receipt photo", systemImage: "photo")
                        }
                        if VNDocumentCameraViewController.isSupported {
                            Button {
                                let permission = AVCaptureDevice.authorizationStatus(for: .video)
                                if permission == .denied || permission == .restricted {
                                    receiptError = "Camera access is off. Enable it in iPhone Settings, choose a photo, or enter this expense manually."
                                } else {
                                    receiptCapture = ReceiptCapture(imageData: nil)
                                }
                            } label: {
                                Label("Scan paper receipt", systemImage: "camera.viewfinder")
                            }
                        }
                        if receiptError?.contains("Camera access is off") == true {
                            Button("Open iPhone Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                        if receiptData != nil {
                            Button("Remove new receipt", role: .destructive) { receiptData = nil }
                        }
                        Text("Review suggested values before saving. Receipt photos stay on this iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let receiptError { Text(receiptError).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(editing == nil ? "New transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { discard = true } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Image(systemName: "checkmark") }
                        .disabled(value == nil || categoryID == nil || !categoryChosenByUser)
                        .accessibilityLabel("Save transaction")
                }
            }
            .onAppear {
                if let editing {
                    amount = NSDecimalNumber(decimal: editing.amount).stringValue
                    title = editing.title
                    categoryID = editing.categoryID ?? store.activeCategories(for: editing.kind).first { $0.name == editing.category }?.id
                    categoryChosenByUser = true
                    paymentMethodID = editing.paymentMethodID
                    selectedPlaceID = editing.location?.placeID
                    unlistedLocation = editing.location?.placeID == nil ? editing.location : nil
                    date = editing.date
                    note = editing.note
                    existingReceipt = ReceiptImageStore.image(for: editing.id)
                } else {
                    categoryID = nil
                }
            }
            .onChange(of: kind) { _, selected in
                categoryChosenByUser = false
                categoryID = store.suggestedCategory(for: selected, title: title)?.categoryID
            }
            .onChange(of: title) { _, changed in
                guard editing == nil, !categoryChosenByUser else { return }
                categoryID = store.suggestedCategory(for: kind, title: changed)?.categoryID
            }
            .confirmationDialog("Discard changes?", isPresented: $discard) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self) {
                            receiptCapture = ReceiptCapture(imageData: data)
                        } else {
                            receiptError = "Could not load that photo. Choose another image or enter the expense manually."
                        }
                    } catch {
                        receiptError = "Could not load that photo. Choose another image or enter the expense manually."
                    }
                    selectedPhoto = nil
                }
            }
            .fullScreenCover(item: $receiptCapture) { capture in
                ReceiptCaptureFlow(initialImageData: capture.imageData,
                                   onError: { receiptError = $0 }) { reviewed in
                    if let amount = reviewed.amount { self.amount = NSDecimalNumber(decimal: amount).stringValue }
                    title = reviewed.merchant
                    if let reviewedDate = reviewed.date { date = reviewedDate }
                    if editing == nil && !categoryChosenByUser {
                        categoryID = store.suggestedCategory(for: kind, title: reviewed.merchant)?.categoryID
                    }
                    receiptData = reviewed.imageData
                    receiptError = nil
                }
            }
            .sheet(isPresented: $showingPlaceEditor) {
                PlaceEditor(store: store) { place in
                    selectedPlaceID = place.id
                    unlistedLocation = nil
                }
            }
            .onReceive(currentLocation.$location.compactMap { $0 }) { location in
                selectedPlaceID = nil
                unlistedLocation = LedgerLocation(placeID: nil, name: "Current location",
                                                  latitude: location.coordinate.latitude,
                                                  longitude: location.coordinate.longitude)
            }
        }
    }
    private func save() {
        guard let value, let categoryID,
              let category = store.activeCategories(for: kind).first(where: { $0.id == categoryID }) else { return }
        let location: LedgerLocation? = selectedPlaceID.flatMap { id in
            store.places.first { $0.id == id }?.location
            ?? (editing?.location?.placeID == id ? editing?.location : nil)
        } ?? unlistedLocation.map { point in
            var named = point
            let enteredName = point.name.trimmingCharacters(in: .whitespacesAndNewlines)
            named.name = enteredName.isEmpty ? "Current location" : enteredName
            return named
        }
        let item = LedgerEntry(id: editing?.id ?? UUID(), kind: kind, amount: value,
                               title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               category: category.name, date: date, note: note,
                               categoryID: categoryID, paymentMethodID: paymentMethodID,
                               location: location)
        if store.save(item) {
            if let receiptData {
                do { try ReceiptImageStore.save(receiptData, for: item.id) }
                catch { store.error = "Expense saved, but the receipt image could not be kept: \(error.localizedDescription)" }
            }
            dismiss()
        }
    }
}
