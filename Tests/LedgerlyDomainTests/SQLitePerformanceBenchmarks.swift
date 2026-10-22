import CoreData
import Foundation
import Testing
@testable import LedgerlyDomain

/// Isolated synthetic SQLite stores only. Ordinary tests skip timings.
@MainActor
struct SQLitePerformanceBenchmarks {
    private struct Measurement: Codable {
        let storedRows: Int
        let operation: String
        let milliseconds: [Double]
        let checksum: String
        var medianMilliseconds: Double { milliseconds.sorted()[milliseconds.count / 2] }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEDGERLY_RUN_SQLITE_BENCHMARKS"] == "1"))
    func measureSQLitePersistence() throws {
        var measurements: [Measurement] = []
        for count in [1_000, 10_000] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-synthetic-sqlite-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("Synthetic.sqlite")
            try autoreleasepool {
                try seed(count: count, url: url)
                let expected = expectedChecksum(count: count)
                measurements.append(try measure(count: count, operation: "reopen, fetch and close") {
                    try autoreleasepool { try CoreDataLedgerRepository(storeURL: url).fetchEntries() }
                } verify: { entries in
                    let actual = checksum(entries)
                    #expect(actual == expected)
                    return actual
                })
                let repository = CoreDataLedgerRepository(storeURL: url)
                measurements.append(try measure(count: count, operation: "fetch on open repository") {
                    try autoreleasepool { try repository.fetchEntries() }
                } verify: { entries in
                    let actual = checksum(entries)
                    #expect(actual == expected)
                    return actual
                })
                let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
                var insertIndex = 0
                measurements.append(try measure(count: count, operation: "insert and save one transaction") {
                    insertIndex += 1
                    let entry = LedgerEntry(id: UUID(), kind: .expense, amount: Decimal(string: "125.55")!,
                        title: "Synthetic insertion \(insertIndex)", category: category.name,
                        date: .now, note: "Synthetic only", categoryID: category.id)
                    try repository.upsert(entry)
                    return entry.id
                } verify: { (id: UUID) in
                    let saved = try #require(try repository.syncEntry(id: id))
                    #expect(saved.amount == Decimal(string: "125.55")! && saved.deletedAt == nil)
                    return "amount=125.55; live=true"
                })
                var updateIndex = 0
                let original = try #require(repository.fetchEntries().first { $0.id == transactionID(1) })
                measurements.append(try measure(count: count, operation: "update and save one transaction") {
                    updateIndex += 1
                    let updated = LedgerEntry(id: original.id, kind: original.kind, amount: original.amount,
                        title: original.title, category: original.category, date: original.date,
                        note: "Synthetic revision \(updateIndex)", categoryID: original.categoryID)
                    try repository.upsert(updated)
                    return updated.note
                } verify: { (note: String) in
                    let saved = try #require(try repository.syncEntry(id: original.id))
                    #expect(saved.note == note && saved.amount == original.amount)
                    return "latest note saved; amount unchanged"
                })
            }
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let environment = ProcessInfo.processInfo.environment
        let rows: [[String: Any]] = measurements.map { row in
            ["storedRows": row.storedRows, "operation": row.operation, "milliseconds": row.milliseconds,
             "medianMilliseconds": row.medianMilliseconds, "checksum": row.checksum]
        }
        let report: [String: Any] = [
            "recordedAt": ISO8601DateFormatter().string(from: .now), "build": build,
            "phase": environment["LEDGERLY_SQLITE_PHASE"] ?? "measurement",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "dataset": "Synthetic; 16 categories; income every fifth row; every tenth row deleted; decimal cents; 50% empty category-history metadata",
            "method": "One warm-up and five samples. Fixture creation, checksum verification and compilation excluded. Reopening includes repository initialization, fetch and teardown; OS filesystem caches are warm. No cloud, UI or device timing.",
            "measurements": rows
        ]
        let output = environment["LEDGERLY_SQLITE_OUTPUT"] ?? "/private/tmp/ledgerly-sqlite-performance.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        for row in measurements {
            print("SQLITE \(row.storedRows) rows | \(row.operation) | \(row.medianMilliseconds) ms")
        }
    }

    private func measure<T>(count: Int, operation: String, body: () throws -> T,
                            verify: (T) throws -> String) throws -> Measurement {
        var samples: [Double] = []
        var expected: String?
        let clock = ContinuousClock()
        for repetition in 0..<6 {
            let start = clock.now
            let result = try body()
            let elapsed = start.duration(to: clock.now).components
            let actual = try verify(result) // Outside the timed interval.
            if let expected { #expect(actual == expected) } else { expected = actual }
            if repetition > 0 { samples.append((Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 1_000) }
        }
        return .init(storedRows: count, operation: operation, milliseconds: samples, checksum: expected ?? "")
    }

    private func checksum(_ entries: [LedgerEntry]) -> String {
        let cents = entries.reduce(Decimal.zero) { $0 + $1.amount * 100 }
        return "\(entries.count):\(cents):\(entries.filter { $0.kind == .income }.count)"
    }

    private func expectedChecksum(count: Int) -> String {
        let live = (0..<count).filter { !$0.isMultiple(of: 10) }
        return "\(live.count):\(live.reduce(0) { $0 + $1 % 499 + 1 }):\(live.filter { $0.isMultiple(of: 5) }.count)"
    }

    private func transactionID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!
    }

    private func seed(count: Int, url: URL) throws {
        let model = CoreDataModel.make()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                       at: url, options: nil)
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let categoryIDs = (0..<16).map { index in
            UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index + 1))!
        }
        for index in categoryIDs.indices {
            let row = NSEntityDescription.insertNewObject(forEntityName: "CategoryRecord", into: context) as! CategoryRecord
            row.id = categoryIDs[index]
            row.name = "Synthetic category \(index)"
            row.kind = index >= 12 ? EntryKind.income.rawValue : EntryKind.expense.rawValue
            row.isArchived = false
            row.isSystem = false
            row.sortIndex = Int16(index)
        }
        let history = try JSONEncoder().encode(CategoryHistoryMetadata())
        let reference = Date(timeIntervalSince1970: 1_792_540_800)
        for index in 0..<count {
            let category = index.isMultiple(of: 5) ? 12 + index % 4 : index % 12
            let row = NSEntityDescription.insertNewObject(forEntityName: "TransactionRecord", into: context) as! TransactionRecord
            row.id = transactionID(index)
            row.kind = index.isMultiple(of: 5) ? EntryKind.income.rawValue : EntryKind.expense.rawValue
            row.amount = NSDecimalNumber(decimal: Decimal(index % 499 + 1) / 100)
            row.title = "Synthetic merchant \(index % 200)"
            row.category = "Synthetic category \(category)"
            row.categoryID = categoryIDs[category]
            row.note = "Synthetic only"
            row.date = reference.addingTimeInterval(-Double(index % 365) * 86_400)
            row.createdAt = reference.addingTimeInterval(-Double(index))
            row.updatedAt = row.createdAt
            row.deletedAt = index.isMultiple(of: 10) ? reference : nil
            row.categorySuggestionData = index.isMultiple(of: 2) ? history : nil
            if (index + 1).isMultiple(of: 1_000) { try context.save(); context.reset() }
        }
        if context.hasChanges { try context.save() }
        context.reset()
    }
}
