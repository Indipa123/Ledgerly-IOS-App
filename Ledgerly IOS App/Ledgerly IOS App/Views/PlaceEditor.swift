import SwiftUI
import MapKit
import Combine

struct PlaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @StateObject private var currentLocation = CurrentLocationService()
    @StateObject private var autocomplete = PlaceAutocompleteService()
    let editing: LedgerPlace?
    let onSaved: (LedgerPlace) -> Void
    @State private var name: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var position: MapCameraPosition
    @State private var validationError: String?
    @State private var searchQuery = ""
    @State private var searchResults: [PlaceSearchCandidate] = []
    @State private var searchError: String?
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var searchGeneration = 0
    @State private var selectedResultID: String?
    @FocusState private var searchFocused: Bool
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 7.8731, longitude: 80.7718),
        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))

    init(store: LedgerStore, editing: LedgerPlace? = nil,
         onSaved: @escaping (LedgerPlace) -> Void = { _ in }) {
        self.store = store
        self.editing = editing
        self.onSaved = onSaved
        _name = State(initialValue: editing?.name ?? "")
        _latitude = State(initialValue: editing.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: editing.map { String($0.longitude) } ?? "")
        let center = CLLocationCoordinate2D(latitude: editing?.latitude ?? 7.8731,
                                             longitude: editing?.longitude ?? 80.7718)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: editing == nil ? 4 : 0.02,
                                   longitudeDelta: editing == nil ? 4 : 0.02))))
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = Double(latitude), let lon = Double(longitude),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                Section("Search for a place") {
                    HStack {
                        TextField("Example: Keels Thelwatte junction", text: $searchQuery)
                            .focused($searchFocused)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.search)
                            .onSubmit(search)
                        Button("Search", action: search)
                            .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    }
                    if isSearching { ProgressView("Searching Maps…") }
                    if let searchError { Text(searchError).font(.footnote).foregroundStyle(.secondary) }
                    if !isSearching && searchResults.isEmpty && !autocomplete.suggestions.isEmpty {
                        Text("Suggestions").font(.footnote).foregroundStyle(.secondary)
                        ForEach(Array(autocomplete.suggestions.enumerated()), id: \.offset) { _, suggestion in
                            Button {
                                search(using: suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.title).font(.subheadline.bold())
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle).font(.footnote).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if hasSearched && !isSearching && searchResults.isEmpty && searchError == nil {
                        Text("No matches found. Try a shorter name, tap the map, or enter coordinates.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !searchResults.isEmpty {
                        Text("Check the address, then select the correct pin before saving.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(searchResults) { result in
                        Button { select(result) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.name).font(.subheadline.bold())
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if selectedResultID == result.id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                    }
                }
                Section("Place") {
                    TextField("Name, for example Keells Nawala", text: $name)
                    Button {
                        searchFocused = false
                        currentLocation.locate()
                    } label: {
                        Label("Use Current Location", systemImage: "location.fill")
                    }
                    .disabled(currentLocation.isLocating)
                    if currentLocation.isLocating { ProgressView("Finding your location…") }
                    if let error = currentLocation.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Choose a search result, use your current location, tap the map, or enter coordinates.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Choose on map") {
                    MapReader { proxy in
                        Map(position: $position) {
                            if let coordinate {
                                Marker("Selected place", coordinate: coordinate)
                            }
                        }
                        .simultaneousGesture(SpatialTapGesture().onEnded { event in
                            if let point = proxy.convert(event.location, from: .local) {
                                latitude = String(format: "%.6f", point.latitude)
                                longitude = String(format: "%.6f", point.longitude)
                                selectedResultID = nil
                            }
                        })
                        .onMapCameraChange { context in visibleRegion = context.region }
                    }
                    .frame(height: 300)
                    .id("selectedPlaceMap")
                    .listRowInsets(EdgeInsets())
                    LabeledContent("Latitude") {
                        TextField("Latitude", text: $latitude)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Longitude") {
                        TextField("Longitude", text: $longitude)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    if let validationError { Text(validationError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(editing == nil ? "Save a place" : "Edit place")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onChange(of: searchQuery) { _, query in
                searchGeneration += 1
                searchResults = []
                searchError = nil
                hasSearched = false
                isSearching = false
                selectedResultID = nil
                autocomplete.update(query: query, region: visibleRegion)
            }
            .onChange(of: selectedResultID) { _, id in
                guard id != nil else { return }
                withAnimation { scroll.scrollTo("selectedPlaceMap", anchor: .center) }
            }
            .onReceive(currentLocation.$location.compactMap { $0 }) { location in
                let point = location.coordinate
                latitude = String(format: "%.6f", point.latitude)
                longitude = String(format: "%.6f", point.longitude)
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = "Current location"
                }
                selectedResultID = nil
                validationError = nil
                position = .region(MKCoordinateRegion(
                    center: point, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
                if !searchQuery.isEmpty { autocomplete.update(query: searchQuery, region: MKCoordinateRegion(
                    center: point, span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))) }
                withAnimation { scroll.scrollTo("selectedPlaceMap", anchor: .center) }
            }
            }
        }
    }

    private func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        performSearch(requests(for: query), matching: query)
    }

    private func search(using suggestion: MKLocalSearchCompletion) {
        let selected = MKLocalSearch.Request(completion: suggestion)
        selected.region = visibleRegion
        performSearch([selected] + requests(for: suggestion.title), matching: suggestion.title)
    }

    private func requests(for query: String) -> [MKLocalSearch.Request] {
        PlaceSearchMatching.variants(for: query).map { variant in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = variant
            request.region = visibleRegion
            return request
        }
    }

    private func performSearch(_ requests: [MKLocalSearch.Request], matching query: String) {
        autocomplete.clear()
        searchFocused = false
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        hasSearched = true
        searchError = nil
        searchResults = []
        Task {
            var candidates: [PlaceSearchCandidate] = []
            var successfulSearches = 0
            for request in requests {
                do {
                    let response = try await MKLocalSearch(request: request).start()
                    successfulSearches += 1
                    candidates += response.mapItems.map { item in
                        let coordinate = item.placemark.coordinate
                        return PlaceSearchCandidate(name: item.name ?? "Map result",
                                                    subtitle: item.placemark.title ?? "",
                                                    latitude: coordinate.latitude,
                                                    longitude: coordinate.longitude)
                    }
                } catch { /* Keep results from the other query spellings. */ }
                guard generation == searchGeneration else { return }
            }
            searchResults = Array(PlaceSearchMatching.ranked(candidates, query: query,
                near: (visibleRegion.center.latitude, visibleRegion.center.longitude)).prefix(12))
            if successfulSearches == 0 {
                searchError = "Search could not load. Check your connection or choose a point on the map."
            }
            isSearching = false
        }
    }

    private func select(_ result: PlaceSearchCandidate) {
        searchFocused = false
        name = result.name
        latitude = String(format: "%.6f", result.latitude)
        longitude = String(format: "%.6f", result.longitude)
        selectedResultID = result.id
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: result.latitude, longitude: result.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
        validationError = nil
    }

    private func save() {
        guard let coordinate else {
            validationError = "Choose a point on the map or enter valid coordinates."
            return
        }
        let place = LedgerPlace(id: editing?.id ?? UUID(),
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard place.isValid else { validationError = "Enter a place name and valid coordinates."; return }
        if store.savePlace(place) { onSaved(place); dismiss() }
    }
}
