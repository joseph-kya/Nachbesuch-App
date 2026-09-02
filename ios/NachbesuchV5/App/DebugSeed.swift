#if DEBUG
import CoreLocation
import Foundation
import SwiftData

/// Generates a synthetic territory for performance work.
///
/// DEBUG-only and opt-in through the launch environment, so it cannot run in a
/// shipped build or touch anyone's real data:
///
///     NACHBESUCH_SEED=5000 xcrun simctl launch booted at.volkshilfe.nachbesuch.v5
///
/// Existing data is left alone; the seeded territory is added alongside it.
enum DebugSeed {
    static var requestedCount: Int? {
        guard let raw = ProcessInfo.processInfo.environment["NACHBESUCH_SEED"],
              let count = Int(raw), count > 0 else { return nil }
        return count
    }

    static func gridDimensions(for count: Int) -> (streets: Int, perStreet: Int) {
        let streets = max(1, Int(Double(count).squareRoot() / 1.6))
        let perStreet = max(1, (count + streets - 1) / streets)
        return (streets, perStreet)
    }

    /// A distinct, digit-free name per street.
    ///
    /// The seed used to emit "Teststraße \(street + 1) \(index + 1)". Geographically
    /// that is a grid, but `StreetNameParser` splits an address at its first digit —
    /// so every one of those addresses reported the street "Teststraße", the list
    /// collapsed the whole grid into one section, and the fixture could not exercise
    /// the grouped list it exists to stress. A letter suffix keeps the names unique
    /// without putting a digit where the house number goes.
    private static func streetName(_ index: Int) -> String {
        var suffix = ""
        var remaining = index
        repeat {
            suffix = String(UnicodeScalar(UInt8(65 + remaining % 26))) + suffix
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return "Teststraße \(suffix)"
    }

    /// Parks the camera over the generated block so a perf run lands on the pins
    /// rather than wherever the map happened to be. Span is overridable:
    ///   SIMCTL_CHILD_NACHBESUCH_SPAN=0.0008
    @MainActor
    private static func parkCamera(streets: Int, perStreet: Int, count: Int) {
        // Derived from the requested count so the camera lands on the block that
        // was actually generated, whatever its size.
        let dimensions = gridDimensions(for: count)
        let effectiveStreets = streets > 0 ? streets : dimensions.streets
        let effectivePerStreet = perStreet > 0 ? perStreet : dimensions.perStreet
        let centreLatitude = 48.2115 + Double(effectiveStreets) * 0.00085 / 2
        let centreLongitude = 16.3105 + Double(effectivePerStreet) * 0.00035 / 2
        let span = ProcessInfo.processInfo.environment["NACHBESUCH_SPAN"].flatMap(Double.init) ?? 0.004
        let defaults = UserDefaults.standard
        defaults.set(centreLatitude, forKey: "map.camera.latitude")
        defaults.set(centreLongitude, forKey: "map.camera.longitude")
        defaults.set(span, forKey: "map.camera.latitudeDelta")
        defaults.set(span, forKey: "map.camera.longitudeDelta")
        defaults.set(true, forKey: "map.didEverCenterOnUser")
    }

    @MainActor
    @discardableResult
    static func populate(_ modelContext: ModelContext, count: Int) -> UUID? {
        let marker = "Testgebiet \(count)"
        let existing = (try? modelContext.fetch(
            FetchDescriptor<Gebiet>(predicate: #Predicate { $0.name == marker })
        )) ?? []
        guard existing.isEmpty else {
            parkCamera(streets: 0, perStreet: 0, count: count)
            return existing.first?.id
        }

        let gebiet = Gebiet(name: marker, districtOrCity: "1160 Wien")
        modelContext.insert(gebiet)

        // A realistic street grid around Ottakring rather than a uniform blanket, so
        // dense streets and stacked pins behave like they do in the field.
        let originLatitude = 48.2115
        let originLongitude = 16.3105
        let dimensions = gridDimensions(for: count)
        let streets = dimensions.streets
        let perStreet = dimensions.perStreet
        let outcomes: [VisitOutcome?] = [nil, .notHome, .notHome, .joined, .earlyNo, .lateNo]

        var made = 0
        var houses: [House] = []
        houses.reserveCapacity(count)

        for street in 0..<streets where made < count {
            let latitude = originLatitude + Double(street) * 0.00085
            for index in 0..<perStreet where made < count {
                let longitude = originLongitude + Double(index) * 0.00035
                let isApartment = index % 7 == 0
                let unitCount = isApartment ? 4 + (index % 5) : 1
                let house = House(
                    address: "\(streetName(street)) \(index + 1)",
                    latitude: latitude,
                    longitude: longitude,
                    gebietID: gebiet.id,
                    isApartmentBuilding: isApartment,
                    unitCount: unitCount
                )
                if var doors = house.decodedUnits() {
                    for doorIndex in doors.indices {
                        doors[doorIndex].outcome = outcomes[(made + doorIndex) % outcomes.count]
                    }
                    house.restore(units: doors)
                }
                modelContext.insert(house)
                houses.append(house)
                made += 1
            }
        }

        try? modelContext.save()

        parkCamera(streets: streets, perStreet: perStreet, count: count)
        print("[DebugSeed] \(made) Häuser in „\(marker)“ angelegt")
        return gebiet.id
    }
}
#endif
