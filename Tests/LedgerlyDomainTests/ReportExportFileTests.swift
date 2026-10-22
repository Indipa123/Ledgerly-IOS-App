import Foundation
import PDFKit
import Testing
@testable import LedgerlyDomain

struct ReportExportFileTests {
    @MainActor @Test func preparedFilesContainTheSelectedReportAndRemainReadableAfterAnotherExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-export-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = LedgerEntry(id: UUID(), kind: .expense, amount: Decimal(string: "430.25")!,
                                title: "Synthetic café", category: "Transport", date: .now,
                                note: "Line one\nLine two")
        let report = try #require(TransactionReport(entries: [entry], startDay: .now, endDay: .now))
        let csv = Data(report.csv(paymentMethods: []).utf8)
        let csvFile = try ReportExportFile(contents: csv, format: .csv, startDay: report.startDay,
                                            endDay: report.endDay, directory: directory)
        let pdf = try ReportPDFRenderer.render(report, paymentMethods: [])
        let pdfFile = try ReportExportFile(contents: pdf, format: .pdf, startDay: report.startDay,
                                            endDay: report.endDay, directory: directory)
        let nextCSV = try ReportExportFile(contents: Data("replacement".utf8), format: .csv,
                                            startDay: report.startDay, endDay: report.endDay, directory: directory)
        #expect(csvFile.url.isFileURL && pdfFile.url.isFileURL)
        #expect(csvFile.url.pathExtension == "csv" && pdfFile.url.pathExtension == "pdf")
        #expect(csvFile.url.lastPathComponent.hasPrefix("Ledgerly-"))
        #expect(csvFile.url != nextCSV.url)
        #expect(try Data(contentsOf: csvFile.url) == csv)
        #expect(try String(contentsOf: csvFile.url, encoding: .utf8).contains("Synthetic café"))
        #expect(try Data(contentsOf: pdfFile.url) == pdf)
        let document = try #require(PDFDocument(url: pdfFile.url))
        #expect(document.pageCount > 0)
        #expect(document.string?.contains("430.25") == true)
        #expect(try Data(contentsOf: nextCSV.url) == Data("replacement".utf8))
    }

    @Test func preparationReportsAnUnwritableDestinationInsteadOfReturningAMissingFile() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-export-blocker-\(UUID())")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        #expect(throws: (any Error).self) {
            try ReportExportFile(contents: Data("report".utf8), format: .csv,
                                 startDay: .now, endDay: .now, directory: blocker)
        }
    }
}
