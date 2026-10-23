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
    var importedLine: StatementLine? = nil
    var suggestedAmount: Decimal? = nil
    @State private var kind: EntryKind
    @State private var amount = ""
    @State private var title = ""
    @State private var categoryID: UUID?
    @State private var categoryChosenByUser = false
    @State private var displayedSuggestion: CategoryMemorySuggestion?
    @State private var displayedAlternatives: [CategoryAlternative] = []
    @State private var predictionHistory = CategoryPredictionHistory()
    @State private var pendingPrediction: CategoryPredictionOutcome?
    @State private var editorScope: UUID?
    @State private var paymentMethodID: UUID?
    @State private var eventID: UUID?
    @State private var selectedPlaceID: UUID?
    @State private var unlistedLocation: LedgerLocation?
    @State private var showingPlaceEditor = false
    @State private var date = Date()
    @State private var note = ""
    @State private var discard = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var receiptCapture: ReceiptCapture?
    @State private var receiptData: Data?
    @State private var additionalReceiptPages: [Data] = []
    @State private var existingReceipt: UIImage?
    @State private var receiptError: String?
    @State private var pendingOverBudgetEntry: LedgerEntry?
    @State private var overrideReason = ""
    @State private var learningEditorID = UUID()

    init(store: LedgerStore, initialKind: EntryKind, editing: LedgerEntry? = nil,
         initialPlaceID: UUID? = nil, importedLine: StatementLine? = nil,
         suggestedAmount: Decimal? = nil) {
        self.store = store
        self.initialKind = initialKind
        self.editing = editing
        self.initialPlaceID = initialPlaceID
        self.importedLine = importedLine
        self.suggestedAmount = suggestedAmount
        _kind = State(initialValue: editing?.kind ?? importedLine?.kind ?? initialKind)
        _selectedPlaceID = State(initialValue: editing?.location?.placeID ?? initialPlaceID)
        _eventID = State(initialValue: editing?.eventID)
    }

    private var rememberedCategory: (category: LedgerCategory, examples: Int, match: CategoryMatch)? {
        guard editing == nil,
              let suggestion = displayedSuggestion,
              let category = store.activeCategories(for: kind).first(where: { $0.id == suggestion.categoryID })
        else { return nil }
        return (category, suggestion.exampleCount, suggestion.match)
    }

    private var value: Decimal? {
        guard let parsed = Decimal(string: amount.replacingOccurrences(of: ",", with: ".")), parsed > 0 else { return nil }
        return parsed
    }
    private var activeAlternatives: [CategoryAlternative] {
        guard editing == nil, displayedSuggestion == nil else { return [] }
        let active = Set(store.activeCategories(for: kind).map(\.id))
        return displayedAlternatives.filter { active.contains($0.categoryID) }
    }

    private var displayedConfidence: Double? {
        guard let suggestion = displayedSuggestion, suggestion.match == .personalModel,
              let model = store.personalLearning.archive.models.first(where: {
                  $0.version == suggestion.modelVersion && $0.kind == kind.rawValue
              }), store.personalLearning.calibratedEstimatesEnabled(for: model) else { return nil }
        return suggestion.estimatedCorrectness
    }
    var body: some View {
        NavigationStack {
            Form {
                if importedLine != nil || suggestedAmount != nil {
                    Text(importedLine != nil
                         ? "Review the statement values and choose a category before saving. Nothing has been added yet."
                         : "The statement amount is filled in for review. Check the expense before saving any change.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Type", selection: $kind) {
                    ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Amount in LKR", text: $amount).keyboardType(.decimalPad)
                VStack(alignment: .leading, spacing: 6) {
                    TextField(kind == .expense ? "Merchant or description (optional)" : "Source or description (optional)", text: $title)
                    Text(kind == .expense
                         ? "Add a merchant or description for category suggestions, or choose a category yourself."
                         : "Add a source or description for category suggestions, or choose a category yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    Text(categorySuggestionExplanation(rememberedCategory))
                        .font(.footnote).foregroundStyle(.secondary)
                    if let estimate = displayedConfidence {
                        Text("Estimated confidence: \(estimate.formatted(.percent.precision(.fractionLength(0)))) · experimental. Check before saving.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if editing == nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No reliable category match yet. Choose one and Ledgerly will remember it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !activeAlternatives.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Possible categories (ranked)").font(.subheadline.weight(.medium))
                        Text("Choose one of these possibilities or use the category picker. A choice is required before saving.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(activeAlternatives) { alternative in
                            Button {
                                guard store.activeCategories(for: kind).contains(where: { $0.id == alternative.id }) else { return }
                                categoryID = alternative.id
                                categoryChosenByUser = true
                            } label: {
                                HStack {
                                    Text(alternative.name).multilineTextAlignment(.leading)
                                    Spacer()
                                    if categoryChosenByUser && categoryID == alternative.id {
                                        Image(systemName: "checkmark.circle.fill")
                                    } else { Text("Use").font(.subheadline.weight(.medium)) }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Choose \(alternative.name) as the category")
                            .accessibilityAddTraits(categoryChosenByUser && categoryID == alternative.id ? .isSelected : [])
                        }
                        Text(activeAlternatives.first?.source == .personalModel
                             ? "Options from your personal on-device model."
                             : "Options from the bundled on-device model.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Picker("Payment method", selection: $paymentMethodID) {
                    Text("Not specified").tag(Optional<UUID>.none)
                    ForEach(store.activePaymentMethods) { method in
                        Label(method.name, systemImage: LedgerIconDescriptor.payment(method.kind).symbol)
                            .tag(Optional(method.id))
                    }
                }
                if kind == .expense {
                    Picker("Event budget (optional)", selection: $eventID) {
                        Text("No event").tag(Optional<UUID>.none)
                        ForEach(store.lifeEvents.filter { $0.completedAt == nil || $0.id == eventID }) { event in
                            Text(event.name).tag(Optional(event.id))
                        }
                    }
                    if let event = store.lifeEvents.first(where: { $0.id == eventID }) {
                        let priorSpend = event.projectedSpent(in: store.entries, adding: 0,
                                                              replacing: editing?.id)
                        let remaining = event.budget - priorSpend
                        Text(remaining >= 0
                             ? "\(LKR.string(remaining)) left in \(event.name) before this expense."
                             : "\(event.name) is already \(LKR.string(-remaining)) over budget before this expense.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                DatePicker("Date & time", selection: $date, displayedComponents: [.date, .hourAndMinute])
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
                        if !additionalReceiptPages.isEmpty { Text("\(additionalReceiptPages.count + 1) receipt pages attached").font(.caption) }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Choose receipt photo", systemImage: "photo")
                        }
                        if VNDocumentCameraViewController.isSupported {
                            Button {
                                let permission = AVCaptureDevice.authorizationStatus(for: .video)
                                if permission == .denied || permission == .restricted {
                                    receiptError = "Camera access is off. Enable it in device Settings, choose a photo, or enter this expense manually."
                                } else {
                                    receiptCapture = ReceiptCapture(imageData: nil)
                                }
                            } label: {
                                Label("Scan paper receipt", systemImage: "camera.viewfinder")
                            }
                        }
                        if receiptError?.contains("Camera access is off") == true {
                            Button("Open device Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                        if receiptData != nil {
                            Button("Remove new receipt", role: .destructive) { receiptData = nil; additionalReceiptPages = [] }
                        }
                        Text("Review suggested values before saving. Signed-in receipt pages sync with your Ledgerly account.")
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
                        .disabled(editorScope != store.categoryLearningScope ||
                                  value == nil || categoryID == nil || !categoryChosenByUser ||
                                  (editing?.eventID.flatMap { id in
                                      store.lifeEvents.first { $0.id == id }?.completedAt
                                  } != nil))
                        .accessibilityLabel("Save transaction")
                }
            }
            .onAppear {
                if editorScope == nil { editorScope = store.categoryLearningScope }
                guard editorScope == store.categoryLearningScope else { dismiss(); return }
                store.personalLearning.editorOpened(learningEditorID)
                if let editing {
                    amount = NSDecimalNumber(decimal: suggestedAmount ?? editing.amount).stringValue
                    title = editing.title
                    categoryID = editing.categoryID ?? store.activeCategories(for: editing.kind).first { $0.name == editing.category }?.id
                    categoryChosenByUser = true
                    paymentMethodID = editing.paymentMethodID
                    eventID = editing.eventID
                    selectedPlaceID = editing.location?.placeID
                    unlistedLocation = editing.location?.placeID == nil ? editing.location : nil
                    date = editing.date
                    note = editing.note
                    existingReceipt = ReceiptImageStore.image(for: editing.id)
                } else if let importedLine {
                    amount = NSDecimalNumber(decimal: importedLine.amount).stringValue
                    title = importedLine.description
                    date = importedLine.date
                }
                refreshSuggestion()
            }
            .onDisappear { store.personalLearning.editorClosed(learningEditorID) }
            .task(id: pendingPrediction) {
                guard let outcome = pendingPrediction else { return }
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { return }
                guard !Task.isCancelled, editorScope == store.categoryLearningScope else { return }
                predictionHistory.append(outcome)
            }
            .onChange(of: store.categoryLearningScope) { _, _ in
                predictionHistory = .init()
                pendingPrediction = nil
                dismiss()
            }
            .onChange(of: kind) { _, selected in
                if selected == .income { eventID = nil }
                categoryChosenByUser = false
                if editing == nil { refreshSuggestion() }
                else {
                    categoryID = store.suggestedCategory(for: selected, title: title,
                                                         placeID: selectedPlaceID)?.categoryID
                }
            }
            .onChange(of: title) { _, _ in refreshSuggestion() }
            .onChange(of: selectedPlaceID) { _, _ in refreshSuggestion() }
            .confirmationDialog("Discard changes?", isPresented: $discard) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self) {
                            receiptCapture = ReceiptCapture(imageData: try ReceiptImageStore.normalizedData(data))
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
                    if let reviewedDate = reviewed.date {
                        date = ReceiptDateSelection.applying(reviewedDate, includesTime: reviewed.includesTime, to: date)
                    }
                    refreshSuggestion()
                    receiptData = reviewed.imageData
                    additionalReceiptPages = reviewed.additionalPages
                    receiptError = nil
                }
            }
            .sheet(isPresented: $showingPlaceEditor) {
                PlaceEditor(store: store) { place in
                    selectedPlaceID = place.id
                    unlistedLocation = nil
                }
            }
            .sheet(item: $pendingOverBudgetEntry) { item in
                NavigationStack {
                    Form {
                        if let event = store.lifeEvents.first(where: { $0.id == item.eventID }) {
                            let previous = event.projectedSpent(in: store.entries,
                                                                adding: 0,
                                                                replacing: editing?.id)
                            let projected = event.projectedSpent(in: store.entries,
                                                                 adding: item.amount,
                                                                 replacing: editing?.id)
                            Section("Over \(event.name)'s budget") {
                                LabeledContent("Remaining before this expense",
                                               value: LKR.string(max(0, event.budget - previous)))
                                LabeledContent("Over by", value: LKR.string(projected - event.budget))
                                Text("You can still save this expense. It will be counted once in monthly spending and linked to this event.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Section("Reason (optional)") {
                            TextField("Why is this over budget?", text: $overrideReason,
                                      axis: .vertical).lineLimit(2...4)
                        }
                    }
                    .navigationTitle("Budget warning")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Review expense") { pendingOverBudgetEntry = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save anyway") {
                                var confirmed = item
                                let reason = overrideReason.trimmingCharacters(in: .whitespacesAndNewlines)
                                confirmed.budgetOverrideReason = reason.isEmpty ? nil : reason
                                pendingOverBudgetEntry = nil
                                commit(confirmed)
                            }
                        }
                    }
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

    private func categorySuggestionExplanation(
        _ suggestion: (category: LedgerCategory, examples: Int, match: CategoryMatch)
    ) -> String {
        switch suggestion.match {
        case .exact:
            "Based on \(suggestion.examples) previous \(suggestion.examples == 1 ? "transaction" : "transactions") with this name. Confirm the category before saving."
        case .similar:
            "Similar to a previous transaction. Check before saving."
        case .model:
            "Suggested from the description. Check before saving."
        case .personalModel:
            "Based on your previous category choices. Check before saving."
        case .place:
            "Based on \(suggestion.examples) expenses recorded at this place. Confirm the category before saving; being nearby does not mean a purchase happened."
        }
    }
    private func refreshSuggestion() {
        guard editing == nil, editorScope == store.categoryLearningScope else { return }
        let assistance = store.categoryAssistance(for: kind, title: title, placeID: selectedPlaceID)
        displayedSuggestion = assistance.suggestion
        displayedAlternatives = assistance.suggestion == nil ? assistance.alternatives : []
        if !categoryChosenByUser { categoryID = displayedSuggestion?.categoryID }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            selectedPlaceID == nil && predictionHistory.events.isEmpty {
            pendingPrediction = nil
        } else {
            pendingPrediction = .init(kind: kind.rawValue,
                source: rememberedCategory == nil ? nil : displayedSuggestion?.match,
                suggestedCategoryID: rememberedCategory?.category.id,
                suggestedCategoryName: rememberedCategory?.category.name,
                modelVersion: rememberedCategory == nil ? nil : displayedSuggestion?.modelVersion,
                alternatives: activeAlternatives)
        }
    }

    private func save() {
        guard editorScope == store.categoryLearningScope, let value, let categoryID,
              let category = store.activeCategories(for: kind).first(where: { $0.id == categoryID }) else { return }
        // Flush the final visible outcome even if Save precedes the debounce deadline.
        if editing == nil, let outcome = pendingPrediction { predictionHistory.append(outcome) }
        let location: LedgerLocation? = selectedPlaceID.flatMap { id in
            store.places.first { $0.id == id }?.location
            ?? (editing?.location?.placeID == id ? editing?.location : nil)
        } ?? unlistedLocation.map { point in
            var named = point
            let enteredName = point.name.trimmingCharacters(in: .whitespacesAndNewlines)
            named.name = enteredName.isEmpty ? "Current location" : enteredName
            return named
        }
        let suggestionRecord: CategorySuggestionRecord?
        if let editing {
            suggestionRecord = editing.categorySuggestion
        } else if let shown = displayedSuggestion, let rememberedCategory {
            suggestionRecord = CategorySuggestionRecord(
                source: shown.match, suggestedCategoryID: shown.categoryID,
                suggestedCategoryName: rememberedCategory.category.name,
                savedCategoryID: categoryID, savedCategoryName: category.name,
                kind: kind.rawValue, recordedAt: .now, modelVersion: shown.modelVersion,
                predictionHistory: predictionHistory.events.isEmpty ? nil : predictionHistory)
        } else {
            suggestionRecord = CategorySuggestionRecord(
                source: nil, suggestedCategoryID: nil, suggestedCategoryName: nil,
                savedCategoryID: categoryID, savedCategoryName: category.name,
                kind: kind.rawValue, recordedAt: .now,
                alternatives: activeAlternatives.isEmpty ? nil : activeAlternatives,
                predictionHistory: predictionHistory.events.isEmpty ? nil : predictionHistory)
        }
        let item = LedgerEntry(id: editing?.id ?? UUID(), kind: kind, amount: value,
                               title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               category: category.name, date: date, note: note,
                               categoryID: categoryID, paymentMethodID: paymentMethodID,
                               location: location, eventID: kind == .expense ? eventID : nil,
                               categorySuggestion: suggestionRecord)
        if let event = store.lifeEvents.first(where: { $0.id == item.eventID }),
           event.projectedSpent(in: store.entries, adding: value,
                                replacing: editing?.id) > event.budget {
            overrideReason = editing?.eventID == event.id ? editing?.budgetOverrideReason ?? "" : ""
            pendingOverBudgetEntry = item
            return
        }
        commit(item)
    }

    private func commit(_ item: LedgerEntry) {
        if store.save(item) {
            if let receiptData {
                do { try ReceiptImageStore.savePages([receiptData] + additionalReceiptPages, for: item.id)
                    store.receiptDidChange(item.id) }
                catch { store.error = "Expense saved, but the receipt image could not be kept: \(error.localizedDescription)" }
            }
            dismiss()
        }
    }
}
