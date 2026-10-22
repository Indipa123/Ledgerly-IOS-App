import SwiftUI

struct ReviewedReceipt {
    var merchant: String
    var amount: Decimal?
    var date: Date?
    var imageData: Data
    var includesTime = false
    var additionalPages: [Data] = []
}

struct ReceiptReviewScreen: View {
    let imagePages: [Data]
    let onCancel: () -> Void
    let onUse: (ReviewedReceipt) -> Void
    @State private var draft = ReceiptReviewDraft()
    @State private var recognitionFinished = false
    @State private var recognitionID: UUID?
    @State private var dateCandidates: [ReceiptDateCandidate] = []
    @State private var lines: [String] = []
    @State private var isRecognizing = true
    @State private var message: String?

    private var amount: Decimal? {
        Decimal(string: draft.amountText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Receipt pages (\(imagePages.count))") {
                    ForEach(Array(imagePages.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                                .accessibilityLabel("Receipt page \(index + 1) of \(imagePages.count)")
                        }
                    }
                    Text("Use pages from one receipt. Review the final total; pages are not added as separate expenses.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Review suggestions") {
                    if isRecognizing { ProgressView("Reading receipt…") }
                    Text("Check every value. Nothing is added until you save the expense.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        TextField("Merchant (optional)", text: Binding(get: { draft.merchant }, set: { draft.setMerchant($0) }))
                        if !draft.merchant.isEmpty { Button("Clear merchant") { draft.setMerchant("") }.font(.caption) }
                    }
                    HStack {
                        TextField("Total in LKR (optional)", text: Binding(get: { draft.amountText }, set: { draft.setAmountText($0) })).keyboardType(.decimalPad)
                        if !draft.amountText.isEmpty { Button("Clear total") { draft.setAmountText("") }.font(.caption) }
                    }
                    Toggle("Use receipt date", isOn: Binding(get: { draft.useDate }, set: { draft.setUseDate($0) }))
                    if draft.useDate {
                        Toggle("Include time", isOn: Binding(get: { draft.includeTime }, set: { draft.setIncludeTime($0) }))
                        if !dateCandidates.contains(where: \.includesTime) {
                            Text("No clear printed time found. You can enter one here, or keep the time chosen in the expense form.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if dateCandidates.count > 1 {
                        Text("More than one date or time is possible. Choose the reading for this purchase:")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(dateCandidates) { candidate in
                            Button {
                                draft.select(candidate)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.date.formatted(date: .long, time: .omitted))
                                        if candidate.includesTime {
                                            Text(timeLabel(candidate.date))
                                                .font(.subheadline)
                                        }
                                        Text(candidate.sourceText.map { "Printed: \($0) · \(candidate.format)" } ?? candidate.format)
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let printedTime = candidate.timeSourceText {
                                            Text("Printed time: \(printedTime)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if draft.useDate && draft.date == candidate.date && draft.includeTime == candidate.includesTime {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                        }
                    }
                    if draft.useDate {
                        DatePicker(draft.includeTime ? "Date & time" : "Date", selection: Binding(get: { draft.date }, set: { draft.setDate($0) }),
                            displayedComponents: draft.includeTime ? [.date, .hourAndMinute] : .date)
                        if draft.includeTime {
                            Text(timeLabel(draft.date)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if !lines.isEmpty {
                    Section("Recognized text") {
                        DisclosureGroup("Show text") {
                            Text(lines.joined(separator: "\n"))
                                .font(.footnote).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Review receipt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use in expense") {
                        onUse(ReviewedReceipt(merchant: draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                                              amount: amount, date: draft.useDate ? draft.date : nil, imageData: imagePages.first ?? Data(),
                                              includesTime: draft.useDate && draft.includeTime, additionalPages: Array(imagePages.dropFirst())))
                    }
                    .disabled(isRecognizing || (!draft.amountText.isEmpty && (amount == nil || amount! <= 0)))
                }
            }
            .task {
                guard !recognitionFinished else { return }
                let requestID = UUID()
                recognitionID = requestID
                isRecognizing = true
                do {
                    let suggestions = try await ReceiptRecognitionService.recognize(imagePages)
                    guard !Task.isCancelled, recognitionID == requestID else { return }
                    draft.apply(suggestions)
                    dateCandidates = suggestions.dateCandidates
                    lines = suggestions.lines
                    if lines.isEmpty { message = "No text found. Enter the values yourself or continue to the expense form." }
                } catch {
                    guard !Task.isCancelled, recognitionID == requestID else { return }
                    message = "Could not read the image. Enter the values yourself or continue to the expense form."
                }
                recognitionFinished = true
                isRecognizing = false
            }
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let zone = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+",
                          abs(offset) / 3_600, abs(offset) % 3_600 / 60)
        return "\(date.formatted(date: .omitted, time: .standard)) · \(zone)"
    }
}
