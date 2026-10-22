import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import UIKit

private struct ReportPDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(data: data)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) { }
}

struct ReportScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var startDay = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var endDay = Date.now
    @State private var includeLocations = false
    @State private var preparedExport: ReportExportFile?
    @State private var exportError: String?

    private var report: TransactionReport? {
        TransactionReport(entries: store.entries, startDay: startDay, endDay: endDay)
    }

    var body: some View {
        Form {
            Section("Date range") {
                DatePicker("From", selection: $startDay, in: ...Date.now, displayedComponents: .date)
                DatePicker("Through", selection: $endDay, in: ...Date.now, displayedComponents: .date)
                if startDay > endDay {
                    Text("Choose an end date on or after the start date.")
                        .foregroundStyle(.red)
                }
            }

            if let report {
                Section("Summary") {
                    LabeledContent("Transactions", value: "\(report.entries.count)")
                    LabeledContent("Income", value: LKR.string(report.income))
                    LabeledContent("Expenses", value: LKR.string(report.expense))
                    LabeledContent("Net", value: LKR.string(report.net))
                }

                if !report.expenseByCategory.isEmpty {
                    Section("Expenses by category") {
                        ForEach(report.expenseByCategory) { item in
                            LabeledContent(item.name, value: LKR.string(item.amount))
                        }
                    }
                }

                Section {
                    Toggle("Include transaction locations", isOn: $includeLocations)
                    if report.entries.isEmpty {
                        Text("No transactions fall within these dates.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            prepare(report, format: .csv)
                        } label: {
                            Label("Export CSV", systemImage: "tablecells")
                        }
                        Button {
                            prepare(report, format: .pdf)
                        } label: {
                            Label("Preview PDF report", systemImage: "doc.richtext")
                        }
                    }
                } header: {
                    Text("Share report")
                } footer: {
                    Text("PDF includes totals, category spending and selected transactions. CSV contains the transaction rows. Both include descriptions and notes; locations are off by default. Receipt images, saved-place lists and visit history are excluded. Review the report before sharing financial data.")
                }
            }
        }
        .navigationTitle("Report")
        .sheet(item: $preparedExport) { file in
            ReportExportScreen(file: file)
        }
        .alert("Could not export report", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Please try again.")
        }
    }

    private func prepare(_ report: TransactionReport, format: ReportFileFormat) {
        do {
            let data: Data
            switch format {
            case .csv:
                data = Data(report.csv(paymentMethods: store.paymentMethods,
                                       includeLocations: includeLocations).utf8)
            case .pdf:
                data = try ReportPDFRenderer.render(report, paymentMethods: store.paymentMethods,
                                                    includeLocations: includeLocations)
            }
            preparedExport = try ReportExportFile(contents: data, format: format,
                                                  startDay: report.startDay, endDay: report.endDay)
        } catch {
            exportError = "Could not prepare the report. Check available storage and try again."
        }
    }
}

private struct ReportExportScreen: View {
    let file: ReportExportFile
    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingExport = false

    private var contentType: UTType { file.format == .pdf ? .pdf : .commaSeparatedText }

    var body: some View {
        NavigationStack {
            Group {
                if file.format == .pdf {
                    ReportPDFView(data: file.contents)
                } else {
                    ContentUnavailableView {
                        Label("CSV report ready", systemImage: "tablecells")
                    } description: {
                        Text(file.url.lastPathComponent)
                        Text("Save the spreadsheet to Files or share it with another app.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                FileExportActions(url: file.url, contents: file.contents, contentType: contentType,
                                  isPresenting: $isPresentingExport)
            }
            .navigationTitle(file.format == .pdf ? "Report preview" : "Export CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isPresentingExport)
                }
            }
        }
        .interactiveDismissDisabled(isPresentingExport)
    }
}
