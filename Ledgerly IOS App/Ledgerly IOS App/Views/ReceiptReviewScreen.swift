import SwiftUI

struct ReviewedReceipt {
    var merchant: String
    var amount: Decimal?
    var date: Date?
    var imageData: Data
}

struct ReceiptReviewScreen: View {
    let imageData: Data
    let onCancel: () -> Void
    let onUse: (ReviewedReceipt) -> Void
    @State private var merchant = ""
    @State private var amountText = ""
    @State private var date = Date()
    @State private var useDate = false
    @State private var dateCandidates: [ReceiptDateCandidate] = []
    @State private var lines: [String] = []
    @State private var isRecognizing = true
    @State private var message: String?

    private var amount: Decimal? {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable().scaledToFit().frame(maxHeight: 240)
                        .accessibilityLabel("Receipt image")
                }
                Section("Review suggestions") {
                    if isRecognizing { ProgressView("Reading receipt…") }
                    Text("Check every value. Nothing is added until you save the expense.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        TextField("Merchant (optional)", text: $merchant)
                        if !merchant.isEmpty { Button("Clear merchant") { merchant = "" }.font(.caption) }
                    }
                    HStack {
                        TextField("Total in LKR (optional)", text: $amountText).keyboardType(.decimalPad)
                        if !amountText.isEmpty { Button("Clear total") { amountText = "" }.font(.caption) }
                    }
                    Toggle("Use receipt date", isOn: $useDate)
                    if dateCandidates.count > 1 {
                        Text("Date order is unclear. Choose the correct reading from the receipt:")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(dateCandidates) { candidate in
                            Button {
                                date = candidate.date
                                useDate = true
                            } label: {
                                HStack {
                                    Text("\(candidate.date.formatted(date: .long, time: .omitted)) · \(candidate.format)")
                                    Spacer()
                                    if useDate && Calendar.current.isDate(date, inSameDayAs: candidate.date) {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                        }
                    }
                    if useDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
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
                        onUse(ReviewedReceipt(merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                                              amount: amount, date: useDate ? date : nil, imageData: imageData))
                    }
                    .disabled(isRecognizing || (!amountText.isEmpty && (amount == nil || amount! <= 0)))
                }
            }
            .task {
                do {
                    let suggestions = try await ReceiptRecognitionService.recognize(imageData)
                    merchant = suggestions.merchant ?? ""
                    amountText = suggestions.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
                    if let suggestedDate = suggestions.date { date = suggestedDate; useDate = true }
                    dateCandidates = suggestions.dateCandidates
                    lines = suggestions.lines
                    if lines.isEmpty { message = "No text found. Enter the values yourself or continue to the expense form." }
                } catch {
                    message = "Could not read the image. Enter the values yourself or continue to the expense form."
                }
                isRecognizing = false
            }
        }
    }
}
