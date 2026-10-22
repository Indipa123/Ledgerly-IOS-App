import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct StatementReconciliationScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var showingImporter = false
    @State private var parsed: ParsedStatement?
    @State private var comparison: ReconciliationResult?
    @State private var importError: String?
    @State private var addingLine: StatementLine?
    @State private var reviewingConflict: ReconciledPair?

    var body: some View {
        List {
            Section {
                Text("Compare a bank or card statement with Ledgerly. Import a CSV or a PDF with selectable text. Ledgerly never adds or changes a transaction until you review and save it.")
                    .font(.subheadline)
                Text("Supported CSV columns: Date, Description, Debit, Credit; or Date, Description, Amount, Type. Text PDFs should put the date first and DR/CR or debit/credit amounts at the end of each line.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { showingImporter = true } label: {
                    Label(parsed == nil ? "Choose statement" : "Choose another statement",
                          systemImage: "doc.badge.arrow.up")
                }
            } footer: {
                Text("Statement files are read on this device and are not uploaded or kept by Ledgerly. Use an LKR statement with four-digit years; ambiguous dates are skipped.")
            }
            if let parsed, let comparison {
                Section("Review summary") {
                    LabeledContent("Statement lines", value: "\(parsed.lines.count)")
                    LabeledContent("Matched", value: "\(comparison.matched.count)")
                    LabeledContent("Amount differences", value: "\(comparison.amountConflicts.count)")
                    LabeledContent("Missing in Ledgerly", value: "\(comparison.missingInApp.count)")
                    LabeledContent("Saved but not on this statement", value: "\(comparison.missingOnStatement.count)")
                    if parsed.skippedRows > 0 {
                        Label("\(parsed.skippedRows) unreadable or unsupported rows were skipped. Check the original file.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if !comparison.amountConflicts.isEmpty {
                    Section("Amount differences") {
                        ForEach(comparison.amountConflicts) { pair in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(pair.statement.description).font(.headline)
                                Text("Statement \(LKR.string(pair.statement.amount)) · Saved \(LKR.string(pair.entry.amount))")
                                    .font(.subheadline)
                                Text(pair.explanation).font(.footnote).foregroundStyle(.secondary)
                                if store.splitBills.contains(where: { $0.entryID == pair.entry.id }) {
                                    Text("Remove this expense's split before changing its amount.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                } else if store.lifeEvents.contains(where: {
                                    $0.id == pair.entry.eventID && $0.completedAt != nil
                                }) {
                                    Text("This expense belongs to a completed event and cannot be changed.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    Button("Review correction") { reviewingConflict = pair }
                                }
                                NavigationLink { EntryDetail(store: store, entry: pair.entry) } label: {
                                    Text("View saved transaction")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if !comparison.missingInApp.isEmpty {
                    Section {
                        ForEach(comparison.missingInApp) { line in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(line.description).font(.headline)
                                        Text(line.date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(LKR.string(line.amount)).font(.subheadline.bold().monospacedDigit())
                                }
                                Text(line.kind.label).font(.caption).foregroundStyle(.secondary)
                                Button("Review and add") { addingLine = line }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Missing in Ledgerly")
                    } footer: {
                        Text("A saved transaction with a different name can appear here. Check the saved-only list before adding a new transaction.")
                    }
                }
                if !comparison.missingOnStatement.isEmpty {
                    Section {
                        ForEach(comparison.missingOnStatement) { entry in
                            NavigationLink { EntryDetail(store: store, entry: entry) } label: {
                                EntryRow(entry: entry)
                            }
                        }
                    } header: {
                        Text("Saved but not on this statement")
                    } footer: {
                        Text("This can happen when a transaction belongs to another account or has not appeared on the bank statement yet. No transaction is changed automatically.")
                    }
                }
                if !comparison.matched.isEmpty {
                    Section("Likely matches") {
                        ForEach(comparison.matched) { pair in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pair.statement.description).font(.subheadline.bold())
                                Text("\(LKR.string(pair.statement.amount)) · \(pair.explanation)")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Reconcile statement")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.commaSeparatedText, .pdf, .plainText]) { outcome in
            importFile(outcome)
        }
        .sheet(item: $addingLine) { line in
            EntryEditor(store: store, initialKind: line.kind, importedLine: line)
        }
        .sheet(item: $reviewingConflict) { pair in
            EntryEditor(store: store, initialKind: pair.entry.kind,
                        editing: pair.entry, suggestedAmount: pair.statement.amount)
        }
        .alert("Could not read statement", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "Choose another file.")
        }
        .onReceive(store.$entries) { _ in
            // @Published emits before the new entries are visible.
            DispatchQueue.main.async { recalculate() }
        }
    }

    private func importFile(_ outcome: Result<URL, Error>) {
        do {
            let url = try outcome.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let statement: ParsedStatement
            if url.pathExtension.lowercased() == "pdf" {
                guard let text = PDFDocument(data: data)?.string else {
                    throw StatementParseError.unreadable
                }
                statement = try StatementParser.pdfText(text)
            } else {
                statement = try StatementParser.csv(data)
            }
            parsed = statement
            recalculate()
        } catch {
            importError = error is StatementParseError ? error.localizedDescription : "Could not read this statement. Check the file and try again."
        }
    }

    private func recalculate() {
        guard let parsed else { return }
        comparison = ReconciliationMatcher.compare(parsed.lines, with: store.entries)
    }
}
