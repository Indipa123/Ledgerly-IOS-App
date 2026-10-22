import Foundation

nonisolated enum ReportFileFormat: String, Sendable {
    case csv, pdf
}

/// Prepare one immutable snapshot before opening a system save/share controller.
/// Keep it on disk after presentation so receiving extensions can finish reading it.
nonisolated struct ReportExportFile: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let contents: Data
    let format: ReportFileFormat

    init(contents: Data, format: ReportFileFormat, startDay: Date, endDay: Date,
         directory: URL = FileManager.default.temporaryDirectory) throws {
        let id = UUID()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "Ledgerly-\(formatter.string(from: startDay))-to-\(formatter.string(from: endDay)).\(format.rawValue)"
        let folder = directory.appendingPathComponent("Ledgerly-Export-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename)
        do {
            try contents.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        self.id = id
        self.url = url
        self.contents = contents
        self.format = format
    }
}
