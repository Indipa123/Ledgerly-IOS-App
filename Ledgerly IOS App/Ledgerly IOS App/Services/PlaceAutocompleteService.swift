import Combine
import MapKit

@MainActor
final class PlaceAutocompleteService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, region: MKCoordinateRegion) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        suggestions = []
        completer.region = region
        completer.queryFragment = trimmed
    }

    func clear() {
        completer.queryFragment = ""
        suggestions = []
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard !completer.queryFragment.isEmpty else { return }
        suggestions = Array(completer.results.prefix(6))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}
