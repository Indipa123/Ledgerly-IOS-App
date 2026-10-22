import Foundation
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ReportPDFError: LocalizedError {
    case rendering
    var errorDescription: String? { "Could not create the PDF. Try a smaller date range." }
}

/// An A4 report with selectable text, flowing notes and repeated page headers.
/// Uses the same selected transactions and location opt-in as CSV export.
enum ReportPDFRenderer {
    static func render(_ report: TransactionReport, paymentMethods: [LedgerPaymentMethod],
                       includeLocations: Bool = false, timeZone: TimeZone = .current) throws -> Data {
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page,
                  [kCGPDFContextTitle: "Ledgerly financial report",
                   kCGPDFContextCreator: "Ledgerly"] as CFDictionary) else { throw ReportPDFError.rendering }
        var closed = false
        defer { if !closed { context.closePDF() } }

        let date = DateFormatter()
        date.timeZone = timeZone
        date.dateStyle = .medium
        let range = "\(date.string(from: report.startDay)) - \(date.string(from: report.endDay))"
        let top: CGFloat = page.height - 100
        let bottom: CGFloat = 50
        let width = page.width - 88
        var cursor = top
        var pageNumber = 0

        func newPage() {
            if pageNumber > 0 { context.endPDFPage() }
            context.beginPDFPage(nil)
            pageNumber += 1
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(page)
            drawLine("LEDGERLY", at: CGPoint(x: 44, y: page.height - 40),
                     size: 18, bold: true, color: accent, context: context)
            drawLine("Financial report | \(range)", at: CGPoint(x: 44, y: page.height - 62),
                     size: 10, context: context)
            context.setStrokeColor(accent)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 44, y: page.height - 78))
            context.addLine(to: CGPoint(x: page.width - 44, y: page.height - 78))
            context.strokePath()
            drawLine("LKR | Personal financial report", at: CGPoint(x: 44, y: 24),
                     size: 9, context: context)
            drawLine("Page \(pageNumber)", at: CGPoint(x: page.width - 88, y: 24),
                     size: 9, context: context)
            cursor = top
        }

        func block(_ text: NSAttributedString) throws {
            let setter = CTFramesetterCreateWithAttributedString(text)
            let fullSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0),
                nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let remaining = cursor - bottom
            if remaining < 60 || (fullSize.height <= top - bottom && fullSize.height > remaining) {
                newPage()
            }
            var offset = 0
            while offset < text.length {
                let path = CGPath(rect: CGRect(x: 44, y: bottom, width: width, height: cursor - bottom),
                                  transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { throw ReportPDFError.rendering }
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                offset += visible.length
                if offset < text.length {
                    newPage()
                } else {
                    let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, visible, nil,
                        CGSize(width: width, height: .greatestFiniteMagnitude), nil)
                    cursor -= ceil(size.height) + 14
                }
            }
        }

        newPage()
        let summary = NSMutableAttributedString(string: "")
        summary.append(styled("OVERVIEW\n", size: 12, bold: true, color: accent))
        summary.append(styled("\(report.entries.count) transactions\n" +
            "Income: \(LKR.string(report.income))\n" +
            "Expenses: \(LKR.string(report.expense))\n" +
            "Net: \(LKR.string(report.net))"))
        try block(summary)

        if !report.expenseByCategory.isEmpty {
            let categories = NSMutableAttributedString(string: "")
            categories.append(styled("EXPENSES BY CATEGORY\n", size: 12, bold: true, color: accent))
            categories.append(styled(report.expenseByCategory.map {
                "\(clean($0.name)): \(LKR.string($0.amount))"
            }.joined(separator: "\n")))
            try block(categories)
        }

        let methods = Dictionary(uniqueKeysWithValues: paymentMethods.map { ($0.id, $0.name) })
        date.timeStyle = .short
        for (index, entry) in report.entries.enumerated() {
            let transaction = NSMutableAttributedString(string: "")
            if index == 0 {
                transaction.append(styled("TRANSACTIONS\n", size: 12, bold: true, color: accent))
            }
            transaction.append(styled("\(entry.kind.label) | \(LKR.string(entry.amount))\n", bold: true))
            var details = [clean(entry.displayTitle), date.string(from: entry.date),
                           "Category: \(clean(entry.category))"]
            if let name = entry.paymentMethodID.flatMap({ methods[$0] }) {
                details.append("Payment: \(clean(name))")
            }
            if !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                details.append("Note: \(clean(entry.note))")
            }
            if includeLocations, let location = entry.location, location.isValid {
                details.append("Place: \(clean(location.name))")
                details.append("Coordinates: \(location.latitude), \(location.longitude)")
            }
            transaction.append(styled(details.joined(separator: "\n")))
            try block(transaction)
        }
        if report.entries.isEmpty { try block(styled("No transactions within this date range.")) }
        context.endPDFPage()
        context.closePDF()
        closed = true
        return data as Data
    }

    private static var accent: CGColor { CGColor(red: 0.60, green: 0.10, blue: 0.24, alpha: 1) }

    private static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        })
    }

    private static func styled(_ text: String, size: CGFloat = 11, bold: Bool = false,
                               color: CGColor = CGColor(gray: 0.12, alpha: 1)) -> NSAttributedString {
        let font = CTFontCreateWithName(bold ? "Helvetica-Bold" as CFString : "Helvetica" as CFString, size, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            .paragraphStyle: paragraph
        ])
    }

    private static func drawLine(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false,
                                 color: CGColor = CGColor(gray: 0.3, alpha: 1), context: CGContext) {
        let line = CTLineCreateWithAttributedString(styled(text, size: size, bold: bold, color: color))
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
