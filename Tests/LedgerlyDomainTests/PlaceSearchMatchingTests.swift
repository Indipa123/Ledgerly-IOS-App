import Testing
@testable import LedgerlyDomain

struct PlaceSearchMatchingTests {
    @Test func spacingVariantsIncludeJoinedBusinessName() {
        let variants = PlaceSearchMatching.variants(for: "Digital Tech Labs")
        #expect(variants.first == "Digital Tech Labs")
        #expect(variants.contains("Digital TechLabs"))
        #expect(PlaceSearchMatching.normalized("Digital TECHLABS") ==
                PlaceSearchMatching.normalized("Digital Tech Labs"))
    }

    @Test func ranksNearbyExactNameAndKeepsSeparateLocations() {
        let far = PlaceSearchCandidate(name: "Digital Tech Labs", subtitle: "Other city",
                                       latitude: 7.5, longitude: 80.5)
        let nearby = PlaceSearchCandidate(name: "Digital TECHLABS", subtitle: "Nearby",
                                          latitude: 6.92, longitude: 79.86)
        let duplicate = PlaceSearchCandidate(name: "Digital Tech Labs", subtitle: "Nearby",
                                             latitude: 6.9201, longitude: 79.8601)
        let other = PlaceSearchCandidate(name: "Digital Store", subtitle: "Nearby",
                                         latitude: 6.921, longitude: 79.861)
        let results = PlaceSearchMatching.ranked([far, other, duplicate, nearby],
            query: "Digital Tech Labs", near: (6.92, 79.86))
        #expect(results.count == 3)
        #expect(results[0].subtitle == "Nearby")
        #expect(results[1].subtitle == "Other city")
    }

    @Test func joinedNameFindsDigitalTechlabsBeforeUnrelatedSearchHit() {
        let unrelated = PlaceSearchCandidate(name: "Dinero Tech Labs", subtitle: "Kerala, India",
                                             latitude: 10.032564, longitude: 76.336385)
        let intended = PlaceSearchCandidate(name: "DIGITAL TECHLABS (PVT)",
                                            subtitle: "Joseph lane, Colombo, Sri Lanka",
                                            latitude: 6.894105, longitude: 79.857869)
        let results = PlaceSearchMatching.ranked([unrelated, intended],
            query: "Digital Tech Labs", near: (7.8731, 80.7718))
        #expect(results.first?.name == intended.name)
    }
}
