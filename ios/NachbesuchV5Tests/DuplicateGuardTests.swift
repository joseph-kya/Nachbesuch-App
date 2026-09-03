import CoreLocation
import Testing
@testable import NachbesuchV5

/// The manual add sheet must offer to *open* the existing house rather than
/// silently doubling it (B8). The match rule: same normalised address, or the
/// same normalised address within 12 m — a different address nearby is a
/// legitimate second entrance, never a warning.
@Suite("Duplikatprüfung beim Anlegen")
struct DuplicateGuardTests {
    private func prints(_ houses: (String, Double, Double)...) -> [ExistingHouseFingerprint] {
        houses.map { ExistingHouseFingerprint(address: $0.0, latitude: $0.1, longitude: $0.2) }
    }

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)
    }

    @Test func sameAddressDifferentCaseMatches() {
        let index = HouseDuplicateIndex(
            fingerprints: prints(("Alte Straße 1", 48.2082, 16.3738)),
            coordinate: center
        )
        #expect(index.duplicate(for: "alte strasse 1") == "Alte Straße 1")
    }

    @Test func differentAddressEightMetresAwayIsNoDuplicate() {
        // ~8 m north, clearly another entrance.
        let index = HouseDuplicateIndex(
            fingerprints: prints(("Alte Straße 1", 48.2082, 16.3738)),
            coordinate: CLLocationCoordinate2D(latitude: 48.208272, longitude: 16.3738)
        )
        #expect(index.duplicate(for: "Alte Straße 2") == nil)
    }

    @Test func differentAddressThirtyMetresAwayIsNoDuplicate() {
        let index = HouseDuplicateIndex(
            fingerprints: prints(("Alte Straße 1", 48.2082, 16.3738)),
            coordinate: CLLocationCoordinate2D(latitude: 48.20847, longitude: 16.3738)
        )
        #expect(index.duplicate(for: "Alte Straße 2") == nil)
    }

    @Test func blankAddressNeverMatches() {
        let index = HouseDuplicateIndex(
            fingerprints: prints(("Alte Straße 1", 48.2082, 16.3738)),
            coordinate: center
        )
        #expect(index.duplicate(for: "   ") == nil)
    }
}
