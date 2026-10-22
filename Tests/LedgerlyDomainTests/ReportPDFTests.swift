import Foundation
import PDFKit
import Testing
@testable import LedgerlyDomain

struct ReportPDFTests {
    private func report(_ entries: [LedgerEntry]) throws -> TransactionReport {
        try #require(TransactionReport(entries: entries, startDay: .now, endDay: .now))
    }

    private func entry(title: String = "Weekly groceries", note: String = "") -> LedgerEntry {
        LedgerEntry(id: UUID(), kind: .expense, amount: Decimal(string: "3450.25")!,
                    title: title, category: "Groceries", date: .now, note: note)
    }

    @MainActor @Test func pdfHasReadableSummaryAndLocationsRequireOptIn() throws {
        var transaction = entry(note: "Personal note")
        transaction.location = LedgerLocation(placeID: nil, name: "PRIVATE_LOCATION_SENTINEL",
                                             latitude: 6.9, longitude: 79.8)
        let report = try report([transaction])
        let data = try ReportPDFRenderer.render(report, paymentMethods: [])
        #expect(data.starts(with: Data("%PDF".utf8)))
        let document = try #require(PDFDocument(data: data))
        let text = try #require(document.string)
        #expect(text.contains("OVERVIEW"))
        #expect(text.contains("EXPENSES BY CATEGORY"))
        #expect(text.contains("Weekly groceries"))
        #expect(text.contains("Personal note"))
        #expect(text.contains("3,450.25"))
        #expect(!text.contains("PRIVATE_LOCATION_SENTINEL"))
        #expect(!text.contains("Coordinates:"))
        let withLocations = try ReportPDFRenderer.render(report, paymentMethods: [], includeLocations: true)
        #expect(PDFDocument(data: withLocations)?.string?.contains("PRIVATE_LOCATION_SENTINEL") == true)
        let bounds = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(bounds.width - 595.28) < 1)
        #expect(abs(bounds.height - 841.89) < 1)
    }

    @MainActor @Test func longNotesAndManyTransactionsContinueAcrossPagesWithoutLosingText() throws {
        let note = String(repeating: "This longer note must wrap and continue onto the next page. ", count: 120) + "END_OF_LONG_NOTE"
        let entries = (0..<24).map { i in
            entry(title: "Transaction \(i)", note: i == 0 ? note : "Reviewed purchase \(i)")
        }
        let data = try ReportPDFRenderer.render(try report(entries), paymentMethods: [])
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 1)
        let text = try #require(document.string)
        #expect(text.contains("END_OF_LONG_NOTE"))
        for index in entries.indices { #expect(text.contains("Transaction \(index)")) }
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect(page.string?.contains("LEDGERLY") == true)
            #expect(page.string?.contains("Page \(index + 1)") == true)
        }
        // Opt-in visual QA writes synthetic fixtures only, never real account records.
        if let folder = ProcessInfo.processInfo.environment["LEDGERLY_PDF_QA_DIR"] {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("report-sample.pdf"))
            for index in 0..<document.pageCount {
                let thumbnail = try #require(document.page(at: index))
                    .thumbnail(of: CGSize(width: 800, height: 1132), for: .mediaBox)
                let bitmap = try #require(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent("page-\(index + 1).png"))
            }
        }
    }

    @MainActor @Test func emptyReportProducesAValidDocument() throws {
        let document = try #require(PDFDocument(data: ReportPDFRenderer.render(try report([]), paymentMethods: [])))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("No transactions within this date range.") == true)
    }
}
