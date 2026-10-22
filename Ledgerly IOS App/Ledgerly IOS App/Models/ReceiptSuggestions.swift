import Foundation

nonisolated struct ReceiptSuggestions: Sendable {
    var merchant: String?
    var amount: Decimal?
    var date: Date?
    var dateCandidates: [ReceiptDateCandidate]
    var lines: [String]
    var dateIncludesTime = false
}

nonisolated struct ReceiptDateCandidate: Identifiable, Sendable {
    let date: Date
    let format: String
    var sourceText: String? = nil
    var timeSourceText: String? = nil
    var includesTime: Bool { timeSourceText != nil }
    var id: String { "\(date.timeIntervalSince1970)-\(format)" }
}

enum ReceiptTextParser {
    nonisolated static func parse(_ lines: [String], asOf: Date = .now,
                                  calendar suppliedCalendar: Calendar = .current) -> ReceiptSuggestions {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = suppliedCalendar.timeZone
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let merchant = cleaned.prefix(5).first { line in
            line.rangeOfCharacter(from: .letters) != nil &&
            !line.lowercased().contains("receipt") &&
            !line.lowercased().contains("invoice") &&
            !line.lowercased().contains("date") &&
            !line.lowercased().contains("total") &&
            !isNonPurchaseDateLine(line) &&
            !isStandaloneTimeLine(line) &&
            dateCandidates(in: line, asOf: asOf, calendar: calendar).isEmpty
        }
        let totalLines = cleaned.filter { line in
            let lower = line.lowercased()
            return (lower.contains("total") || lower.contains("amount due")) &&
                !lower.contains("subtotal") && !lower.contains("sub total") &&
                !lower.contains("tax") && !lower.contains("saving")
        }
        let amount = totalLines.reversed().compactMap(lastAmount(in:)).first
        // Keep distinct readings from every line. A header/expiry date must not
        // silently win over a different purchase date later in the receipt.
        var dates: [ReceiptDateCandidate] = []
        for (index, line) in cleaned.enumerated() {
            let dayOptions = dateCandidates(in: line, asOf: asOf, calendar: calendar)
            var clocks = timeCandidates(in: line)
            // Do not pair one clock with several different printed date tokens.
            if Set(dayOptions.compactMap(\.sourceText)).count != 1 { clocks = [] }
            else if clocks.isEmpty, index + 1 < cleaned.count,
                    isStandaloneTimeLine(cleaned[index + 1]),
                    dateCandidates(in: cleaned[index + 1], asOf: asOf, calendar: calendar).isEmpty {
                clocks = timeCandidates(in: cleaned[index + 1])
            }
            for day in dayOptions {
                let timed = clocks.flatMap { combining(day, time: $0, calendar: calendar) }
                for candidate in timed.isEmpty ? [day] : timed {
                    if candidate.includesTime {
                        dates.removeAll { !$0.includesTime && calendar.isDate($0.date, inSameDayAs: candidate.date) }
                        if !dates.contains(where: { $0.includesTime && $0.date == candidate.date }) { dates.append(candidate) }
                    } else if !dates.contains(where: { calendar.isDate($0.date, inSameDayAs: candidate.date) }) {
                        dates.append(candidate)
                    }
                }
            }
        }
        let ordered = dates.enumerated().sorted {
            let left = distance($0.element.date, from: asOf)
            let right = distance($1.element.date, from: asOf)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        return ReceiptSuggestions(merchant: merchant, amount: amount,
                                  date: ordered.count == 1 ? ordered.first?.date : nil,
                                  dateCandidates: ordered, lines: cleaned,
                                  dateIncludesTime: ordered.count == 1 && ordered[0].includesTime)
    }

    nonisolated private static func lastAmount(in line: String) -> Decimal? {
        let pattern = #"\b\d{1,3}(?:,\d{3})+(?:\.\d{2})?\b|\b\d+(?:\.\d{2})?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).reversed().compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            return Decimal(string: line[range].replacingOccurrences(of: ",", with: ""))
        }.first
    }

    nonisolated private static func distance(_ date: Date, from reference: Date) -> TimeInterval {
        abs(date.timeIntervalSince(reference))
    }

    nonisolated private static func isNonPurchaseDateLine(_ line: String) -> Bool {
        line.range(of: #"\b(?:exp(?:iry|iration|ires)?|best\s+before|use\s+by|valid\s+(?:until|to))\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private struct PrintedTime: Sendable {
        let hour: Int
        let minute: Int
        let second: Int
        let source: String
        let offsetSeconds: Int?
        let fraction: TimeInterval
    }

    nonisolated private static func timeCandidates(in line: String) -> [PrintedTime] {
        guard !isNonPurchaseDateLine(line) else { return [] }
        // Abbreviations such as IST/CST have several meanings. Require an
        // explicit numeric offset or UTC/GMT instead of inventing a timezone.
        if line.range(of: #"\d{1,2}:\d{2}(?::\d{2})?\s+(?:IST|CST|PST|EST|BST|EDT|PDT|AEST|AEDT|CET|CEST)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return [] }
        // A label colon is not a preceding clock component. Remove only known
        // labels so the boundary check can still reject partial invalid clocks.
        let clockLine = line.replacingOccurrences(of: #"(?<=\d)[Tt](?=\d{1,2}:)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:time|t)\s*:\s*(?=\d)"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
        var result: [PrintedTime] = []
        func add(_ hourText: String, _ minuteText: String, _ secondText: String,
                 _ meridiem: String, source: String, zone: String = "", fraction: String = "") {
            guard var hour = Int(hourText), let minute = Int(minuteText), let second = Int(secondText),
                  (0...59).contains(minute), (0...59).contains(second) else { return }
            if !meridiem.isEmpty {
                guard (1...12).contains(hour) else { return }
                hour = hour % 12 + (meridiem.lowercased() == "p" ? 12 : 0)
            } else if !(0...23).contains(hour) { return }
            var offset: Int?
            if !zone.isEmpty {
                let normalized = zone.uppercased().replacingOccurrences(of: "UTC", with: "")
                    .replacingOccurrences(of: "GMT", with: "").replacingOccurrences(of: " ", with: "")
                if normalized.isEmpty || normalized == "Z" { offset = 0 }
                else {
                    let digits = normalized.dropFirst().replacingOccurrences(of: ":", with: "")
                    guard (normalized.first == "+" || normalized.first == "-"), digits.count == 4,
                          let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                          hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return }
                    offset = (hours * 3600 + minutes * 60) * (normalized.first == "-" ? -1 : 1)
                }
            }
            let subsecond = fraction.isEmpty ? 0 : Double("0." + fraction) ?? 0
            if !result.contains(where: { $0.hour == hour && $0.minute == minute && $0.second == second && $0.offsetSeconds == offset && $0.fraction == subsecond }) {
                result.append(.init(hour: hour, minute: minute, second: second,
                    source: source.trimmingCharacters(in: .whitespacesAndNewlines), offsetSeconds: offset, fraction: subsecond))
            }
        }
        func matches(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            return regex.matches(in: clockLine, range: NSRange(clockLine.startIndex..<clockLine.endIndex, in: clockLine)).map { match in
                (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: clockLine).map { String(clockLine[$0]) } ?? "" }
            }
        }
        for parts in matches(#"(?<![\p{L}\p{N}:])(\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?(?:\s*([ap])\.?\s*m\.?)?(?:\s*(Z\b|(?:UTC|GMT)(?:\s*[+-]\d{2}:?\d{2})?|[+-]\d{2}:?\d{2}))?(?![\p{L}\p{N}:])"#) {
            add(parts[1], parts[2], parts[3].isEmpty ? "0" : parts[3], parts[5], source: parts[0], zone: parts[6], fraction: parts[4])
        }
        for parts in matches(#"(?<![\p{L}\p{N}:])(\d{1,2})\s*([ap])\.?\s*m\.?(?![\p{L}\p{N}:])"#) {
            add(parts[1], "0", "0", parts[2], source: parts[0])
        }
        return result
    }

    nonisolated private static func isStandaloneTimeLine(_ line: String) -> Bool {
        let times = timeCandidates(in: line)
        guard !times.isEmpty else { return false }
        if line.range(of: #"^\s*(?:time|t)\s*[:=-]"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return times.count == 1 && line.trimmingCharacters(in: .whitespacesAndNewlines) == times[0].source
    }

    nonisolated private static func combining(_ candidate: ReceiptDateCandidate, time: PrintedTime,
                                             calendar: Calendar) -> [ReceiptDateCandidate] {
        if let offset = time.offsetSeconds, let zone = TimeZone(secondsFromGMT: offset) {
            var zonedCalendar = Calendar(identifier: .gregorian); zonedCalendar.timeZone = zone
            var parts = calendar.dateComponents([.year, .month, .day], from: candidate.date)
            parts.hour = time.hour; parts.minute = time.minute; parts.second = time.second
            guard let date = zonedCalendar.date(from: parts) else { return [] }
            return [.init(date: date.addingTimeInterval(time.fraction), format: candidate.format,
                          sourceText: candidate.sourceText, timeSourceText: time.source)]
        }
        let start = calendar.startOfDay(for: candidate.date).addingTimeInterval(-1)
        let parts = DateComponents(hour: time.hour, minute: time.minute, second: time.second)
        var result: [ReceiptDateCandidate] = []
        // A missing daylight-saving time is left for manual entry. Both occurrences
        // of a repeated clock time are separate choices with timezone labels.
        for policy: Calendar.RepeatedTimePolicy in [.first, .last] {
            guard let date = calendar.nextDate(after: start, matching: parts, matchingPolicy: .strict,
                                               repeatedTimePolicy: policy),
                  calendar.isDate(date, inSameDayAs: candidate.date),
                  !result.contains(where: { $0.date == date }) else { continue }
            result.append(.init(date: date.addingTimeInterval(time.fraction), format: candidate.format, sourceText: candidate.sourceText,
                                timeSourceText: time.source))
        }
        return result
    }

    nonisolated private static func dateCandidates(in line: String, asOf: Date,
                                                  calendar: Calendar) -> [ReceiptDateCandidate] {
        // Explicit non-purchase labels are excluded. Unlabelled competing dates
        // remain choices for the user rather than relying on line order.
        if isNonPurchaseDateLine(line) { return [] }
        let currentYear = calendar.component(.year, from: asOf)
        func year(_ twoDigits: Int) -> Int {
            let candidate = (currentYear / 100) * 100 + twoDigits
            return candidate > currentYear + 1 ? candidate - 100 : candidate
        }
        var options: [ReceiptDateCandidate] = []
        func add(_ year: Int, _ month: Int, _ day: Int, _ format: String, source: String) {
            guard (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return }
            let parts = DateComponents(year: year, month: month, day: day, hour: 12)
            guard let date = calendar.date(from: parts),
                  calendar.component(.year, from: date) == year,
                  calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day else { return }
            if !options.contains(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                options.append(ReceiptDateCandidate(date: date, format: format, sourceText: source))
            }
        }
        func matches(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return regex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)).map { match in
                (0..<match.numberOfRanges).map { index in
                    Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
                }
            }
        }
        let numeric = #"\b(\d{4}|\d{1,2})\s*([/.-])\s*(\d{1,2})\s*\2\s*(\d{4}|\d{1,2})(?=\b|[Tt]\d{1,2}:)"#
        for parts in matches(numeric) {
            guard let first = Int(parts[1]), let second = Int(parts[3]), let third = Int(parts[4]) else { continue }
            let source = parts[0]
            if parts[1].count == 4 {
                add(first, second, third, "YYYY-MM-DD", source: source)
            } else if parts[4].count == 4 {
                add(third, second, first, "DD-MM-YYYY", source: source)
                add(third, first, second, "MM-DD-YYYY", source: source)
            } else {
                guard parts[4].count == 2 else { continue }
                add(year(first), second, third, "YY-MM-DD", source: source)
                add(year(third), second, first, "DD-MM-YY", source: source)
                add(year(third), first, second, "MM-DD-YY", source: source)
            }
        }
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let month = #"(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?"#
        let separator = #"[\s,./-]+"#
        for parts in matches(#"\b(\d{1,2})(?:st|nd|rd|th)?"# + separator + month + separator + #"(\d{4}|\d{2})\b"#) {
            if let day = Int(parts[1]), let month = months[String(parts[2].lowercased().prefix(3))], let number = Int(parts[3]) {
                add(parts[3].count == 4 ? number : year(number), month, day,
                    parts[3].count == 4 ? "DD-MMM-YYYY" : "DD-MMM-YY", source: parts[0])
            }
        }
        for parts in matches(#"\b"# + month + separator + #"(\d{1,2})(?:st|nd|rd|th)?"# + separator + #"(\d{4}|\d{2})\b"#) {
            if let month = months[String(parts[1].lowercased().prefix(3))], let day = Int(parts[2]), let number = Int(parts[3]) {
                add(parts[3].count == 4 ? number : year(number), month, day,
                    parts[3].count == 4 ? "MMM-DD-YYYY" : "MMM-DD-YY", source: parts[0])
            }
        }
        for parts in matches(#"\b(\d{4})"# + separator + month + separator + #"(\d{1,2})\b"#) {
            if let year = Int(parts[1]), let month = months[String(parts[2].lowercased().prefix(3))], let day = Int(parts[3]) {
                add(year, month, day, "YYYY-MMM-DD", source: parts[0])
            }
        }
        return options
    }
}

enum ReceiptDateSelection {
    nonisolated static func applying(_ receiptDate: Date, includesTime: Bool, to editorDate: Date,
                                     calendar: Calendar = .current) -> Date {
        guard !includesTime else { return receiptDate }
        // A date-only receipt supplies no clock: preserve the editor's chosen
        // time rather than importing the parser's noon date-validation anchor.
        let clock = calendar.dateComponents([.hour, .minute, .second], from: editorDate)
        return calendar.date(bySettingHour: clock.hour ?? 12, minute: clock.minute ?? 0,
            second: clock.second ?? 0, of: receiptDate) ?? receiptDate
    }
}
