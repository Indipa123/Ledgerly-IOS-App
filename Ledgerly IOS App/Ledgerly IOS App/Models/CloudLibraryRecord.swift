import Foundation
import CryptoKit

nonisolated enum LibraryKind: String, Codable, CaseIterable, Sendable {
    case category, payment, reminder, place, receipt, avatar
}

nonisolated struct CloudLibraryRecord: Codable, Equatable, Sendable {
    static let maximumBytes = 3_800_000
    static let chunkBytes = 256_000
    let kind: LibraryKind
    let id: String
    let updatedAt: Date
    let revision: UUID
    let payload: Data?
    var key: String { "library-\(kind.rawValue)-\(id)" }
    var digest: String { Self.digest(payload ?? Data()) }
    var chunks: [Data] {
        guard let payload else { return [] }
        return stride(from: 0, to: payload.count, by: Self.chunkBytes).map {
            payload.subdata(in: $0..<min(payload.count, $0 + Self.chunkBytes))
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func assemble(_ chunks: [Data], byteCount: Int, digest: String) throws -> Data {
        guard byteCount >= 0, byteCount <= maximumBytes,
              chunks.count <= 15, chunks.allSatisfy({ $0.count <= chunkBytes }) else { throw CocoaError(.fileReadCorruptFile) }
        let data = chunks.reduce(into: Data()) { $0.append($1) }
        guard data.count == byteCount, Self.digest(data) == digest else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

/// Durable offline outbox. Untouched legacy values start older than cloud records;
/// actual local edits use their edit time and a revision for deterministic ties.
nonisolated struct CloudLibraryJournal: Codable {
    private(set) var records: [String: CloudLibraryRecord] = [:]
    private(set) var pending: Set<String> = []
    private(set) var bootstrapped = false
    private(set) var referencesUpgraded = false
    mutating func finishReferenceUpgrade() { referencesUpgraded = true }

    private enum CodingKeys: String, CodingKey { case records, pending, bootstrapped, referencesUpgraded }
    init() { }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decodeIfPresent([String: CloudLibraryRecord].self, forKey: .records) ?? [:]
        pending = try values.decodeIfPresent(Set<String>.self, forKey: .pending) ?? Set(records.keys)
        bootstrapped = try values.decodeIfPresent(Bool.self, forKey: .bootstrapped) ?? false
        referencesUpgraded = try values.decodeIfPresent(Bool.self, forKey: .referencesUpgraded) ?? false
    }

    mutating func capture(kind: LibraryKind, id: String, payload: Data?, at date: Date = .now,
                          legacy: Bool = false) throws {
        guard payload.map({ $0.count <= CloudLibraryRecord.maximumBytes }) ?? true else { throw CocoaError(.fileWriteOutOfSpace) }
        let key = "library-\(kind.rawValue)-\(id)"
        if let old = records[key], old.payload == payload { return }
        let record = CloudLibraryRecord(kind: kind, id: id, updatedAt: legacy ? Date(timeIntervalSince1970: 0) : date,
                                       revision: UUID(), payload: payload)
        records[key] = record
        pending.insert(key)
    }

    mutating func observe(_ values: [LibraryKind: [String: Data]], at date: Date = .now) throws {
        for (kind, values) in values {
            for (id, payload) in values { try capture(kind: kind, id: id, payload: payload, at: date, legacy: !bootstrapped) }
            for record in Array(records.values) where record.kind == kind && record.payload != nil && values[record.id] == nil {
                try capture(kind: kind, id: record.id, payload: nil, at: date)
            }
        }
        bootstrapped = true
    }

    static func newer(_ left: CloudLibraryRecord, than right: CloudLibraryRecord) -> Bool {
        left.updatedAt != right.updatedAt ? left.updatedAt > right.updatedAt : left.revision.uuidString > right.revision.uuidString
    }
    func accepts(_ remote: CloudLibraryRecord) -> Bool {
        records[remote.key].map { Self.newer(remote, than: $0) } ?? true
    }
    mutating func accept(_ remote: CloudLibraryRecord) {
        records[remote.key] = remote; pending.remove(remote.key)
    }
    mutating func acknowledge(_ sent: CloudLibraryRecord) {
        if records[sent.key]?.revision == sent.revision { pending.remove(sent.key) }
    }
}

nonisolated enum StableLibraryID {
    static func make(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("Ledgerly/" + value).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBufferPointer { UUID(uuidString: NSUUID(uuidBytes: $0.baseAddress!).uuidString)! }
    }
}
