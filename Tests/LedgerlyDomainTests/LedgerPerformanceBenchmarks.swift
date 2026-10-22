import Foundation
import Testing
@testable import LedgerlyDomain

/// Opt-in synthetic measurements. No timing threshold is enforced on ordinary test runs.
@MainActor
struct LedgerPerformanceBenchmarks {
    private struct Measurement: Encodable {
        let entries: Int
        let operation: String
        let milliseconds: [Double]
        let checksum: String
        var medianMilliseconds: Double { milliseconds.sorted()[milliseconds.count / 2] }

        enum CodingKeys: String, CodingKey {
            case entries, operation, milliseconds, checksum, medianMilliseconds
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(entries, forKey: .entries)
            try values.encode(operation, forKey: .operation)
            try values.encode(milliseconds, forKey: .milliseconds)
            try values.encode(checksum, forKey: .checksum)
            try values.encode(medianMilliseconds, forKey: .medianMilliseconds)
        }
    }

    private struct Report: Encodable {
        let recordedAt = Date()
        let phase: String
        let build: String
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let processorCount = ProcessInfo.processInfo.processorCount
        let calendar = "Gregorian / Asia/Colombo"
        let dataset = "Synthetic; 365 days; income every fifth entry; 12 expense categories"
        let repetitions = 5
        let measurements: [Measurement]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEDGERLY_RUN_BENCHMARKS"] == "1"))
    func measureLargeLedgerCalculations() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Colombo")!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        let days = (0..<365).map { calendar.date(byAdding: .day, value: -$0, to: asOf)! }
        var measurements: [Measurement] = []
        for count in [10_000, 50_000] {
            let entries = (0..<count).map { index in
                LedgerEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                    kind: index.isMultiple(of: 5) ? .income : .expense,
                    amount: Decimal(index % 499 + 1), title: "Synthetic merchant \(index % 200)",
                    category: "Category \(index % 12)", date: days[index % 365], note: "")
            }
            let trend = InsightCalculations.dailyExpenses(entries, asOf: asOf, calendar: calendar)
            let firstDay = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: asOf))!
            let expected = entries.filter { $0.kind == .expense && $0.date >= firstDay && $0.date <= asOf }
                .reduce(Decimal.zero) { $0 + $1.amount }
            #expect(trend.count == 30 && trend.reduce(Decimal.zero) { $0 + $1.expense } == expected)
            measurements.append(measure(count: count, operation: "30-day expense trend") {
                InsightCalculations.dailyExpenses(entries, asOf: asOf, calendar: calendar)
                    .map { NSDecimalNumber(decimal: $0.expense).stringValue }.joined(separator: ",")
            })
            measurements.append(measure(count: count, operation: "6-month income/expense totals") {
                InsightCalculations.monthlyTotals(entries, asOf: asOf, calendar: calendar)
                    .map { "\($0.income):\($0.expense)" }.joined(separator: ",")
            })
            measurements.append(measure(count: count, operation: "Current-month category totals") {
                InsightCalculations.categoryTotals(entries, asOf: asOf, calendar: calendar)
                    .map { "\($0.name):\($0.amount)" }.joined(separator: ",")
            })
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let environment = ProcessInfo.processInfo.environment
        let report = Report(phase: environment["LEDGERLY_BENCHMARK_PHASE"] ?? "measurement",
            build: build, measurements: measurements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let output = environment["LEDGERLY_BENCHMARK_OUTPUT"] ?? "/private/tmp/ledgerly-performance.json"
        try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
        for row in measurements {
            print("BENCHMARK \(row.entries) entries | \(row.operation) | median \(row.medianMilliseconds) ms")
        }
    }

    private func measure(count: Int, operation: String, body: () -> String) -> Measurement {
        let expected = body() // Warm-up is outside the measured repetitions.
        let clock = ContinuousClock()
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = clock.now
            let checksum = body()
            let duration = start.duration(to: clock.now).components
            timings.append((Double(duration.seconds) + Double(duration.attoseconds) / 1e18) * 1_000)
            #expect(checksum == expected)
        }
        return .init(entries: count, operation: operation, milliseconds: timings, checksum: expected)
    }
}
