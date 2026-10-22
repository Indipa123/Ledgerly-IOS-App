import Foundation

nonisolated struct ReceiptPageArchive: Codable, Equatable {
    static let maximumPages = 10
    static let maximumPageBytes = 256_000
    let pages: [Data]

    init(pages: [Data]) throws {
        guard (1...Self.maximumPages).contains(pages.count),
              pages.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumPageBytes }) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        self.pages = pages
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        return try Self(pages: value.pages)
    }
}
