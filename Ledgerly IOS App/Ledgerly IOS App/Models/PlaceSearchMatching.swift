import Foundation

struct PlaceSearchCandidate: Identifiable {
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var id: String { "\(name):\(latitude):\(longitude)" }
}

enum PlaceSearchMatching {
    static func variants(for query: String) -> [String] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        var variants = [words.joined(separator: " ")]
        if words.count > 1 {
            variants.append((Array(words.dropLast(2)) + [words.suffix(2).joined()]).joined(separator: " "))
        }
        if words.count > 2 {
            variants.append(([words.prefix(2).joined()] + Array(words.dropFirst(2))).joined(separator: " "))
            variants.append(words.joined())
        }
        var seen: Set<String> = []
        return variants.filter { seen.insert($0.lowercased()).inserted }
    }

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func ranked(_ candidates: [PlaceSearchCandidate], query: String,
                       near center: (latitude: Double, longitude: Double)) -> [PlaceSearchCandidate] {
        let wanted = normalized(query)
        let ordered = candidates.enumerated().sorted { left, right in
            let leftTier = matchTier(left.element.name, wanted: wanted)
            let rightTier = matchTier(right.element.name, wanted: wanted)
            if leftTier != rightTier { return leftTier < rightTier }
            let leftDistance = distance(left.element, from: center)
            let rightDistance = distance(right.element, from: center)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return left.offset < right.offset
        }.map(\.element)

        var unique: [PlaceSearchCandidate] = []
        for candidate in ordered {
            let duplicate = unique.contains {
                normalized($0.name) == normalized(candidate.name) &&
                distance($0, from: (candidate.latitude, candidate.longitude)) < 75
            }
            if !duplicate { unique.append(candidate) }
        }
        return unique
    }

    private static func matchTier(_ name: String, wanted: String) -> Int {
        let value = normalized(name)
        if value == wanted { return 0 }
        if !wanted.isEmpty && (value.contains(wanted) || wanted.contains(value)) { return 1 }
        return 2
    }

    private static func distance(_ place: PlaceSearchCandidate,
                                 from center: (latitude: Double, longitude: Double)) -> Double {
        let lat = (place.latitude - center.latitude) * .pi / 180
        let lon = (place.longitude - center.longitude) * .pi / 180
        let meanLat = (place.latitude + center.latitude) * .pi / 360
        return 6_371_000 * sqrt(lat * lat + pow(cos(meanLat) * lon, 2))
    }
}
