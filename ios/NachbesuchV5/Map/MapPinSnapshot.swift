import CoreLocation
import Foundation
import MapKit

/// A house reduced to exactly what the map needs, as plain values that can cross
/// isolation boundaries safely.
nonisolated struct MapPinSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let address: String
    let latitude: Double
    let longitude: Double
    let markerOutcome: VisitOutcome?
    let unitCount: Int
    let completedCount: Int
    let followUpCount: Int
    let joinedCount: Int
    let earlyNoCount: Int
    let lateNoCount: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Glyph baked into the pin bitmap: the outcome emoji for a single household,
    /// a progress counter for an apartment building.
    var markerText: String {
        unitCount == 1 ? markerOutcome.displayEmojiRaw : "\(completedCount)/\(unitCount)"
    }

    var hasOpenWork: Bool { followUpCount > 0 || completedCount < unitCount }
}

/// Presentation helper for the map layer, which deliberately does not import
/// SwiftUI just to pick a glyph.
extension Optional where Wrapped == VisitOutcome {
    nonisolated var displayEmojiRaw: String { self?.emoji ?? "•" }
}

/// Bounding box of every pin in the snapshot — what "show me the whole territory"
/// needs, computed once during the build rather than by scanning pins later.
nonisolated struct MapBounds: Sendable, Equatable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
    }

    /// Padded so pins never sit flush against the screen edge.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.35, 0.004),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.35, 0.004)
            )
        )
    }

    static func around(_ coordinates: [CLLocationCoordinate2D]) -> MapBounds? {
        var minLatitude = Double.greatestFiniteMagnitude
        var maxLatitude = -Double.greatestFiniteMagnitude
        var minLongitude = Double.greatestFiniteMagnitude
        var maxLongitude = -Double.greatestFiniteMagnitude
        var found = false
        for coordinate in coordinates where StoredCoordinate(coordinate).isPlausible {
            found = true
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        guard found else { return nil }
        return MapBounds(
            minLatitude: minLatitude, maxLatitude: maxLatitude,
            minLongitude: minLongitude, maxLongitude: maxLongitude
        )
    }
}

nonisolated struct MapDayStats: Sendable, Equatable {
    let houseCount: Int
    let followUpCount: Int
    let joinedCount: Int
    let openCount: Int
    let earlyNoCount: Int
    let lateNoCount: Int

    static let empty = MapDayStats(
        houseCount: 0, followUpCount: 0, joinedCount: 0,
        openCount: 0, earlyNoCount: 0, lateNoCount: 0
    )
}

/// The immutable pin set the map renders.
nonisolated struct PreparedMapSnapshot: Sendable {
    let pinsByID: [UUID: MapPinSnapshot]
    let stats: MapDayStats
    let bounds: MapBounds?

    init(pinsByID: [UUID: MapPinSnapshot], stats: MapDayStats, bounds: MapBounds? = nil) {
        self.pinsByID = pinsByID
        self.stats = stats
        self.bounds = bounds
    }

    static let empty = PreparedMapSnapshot(pinsByID: [:], stats: .empty)
}

/// Raw house data, decoupled from SwiftData so snapshot building can run off the
/// main actor without carrying `@Model` references across isolation boundaries.
nonisolated struct RawMapHouse: Sendable {
    let id: UUID
    let address: String
    let latitude: Double
    let longitude: Double
    let unitsData: Data

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasPlausibleCoordinate: Bool {
        StoredCoordinate(coordinate).isPlausible
    }

    init(id: UUID, address: String, latitude: Double, longitude: Double, unitsData: Data) {
        self.id = id
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.unitsData = unitsData
    }

    @MainActor
    init(_ house: House) {
        self.init(
            id: house.id,
            address: house.address,
            latitude: house.latitude,
            longitude: house.longitude,
            unitsData: house.unitsData
        )
    }
}

nonisolated enum MapPinSnapshotBuilder {
    static func build(from houses: [RawMapHouse], scope: DayScope) -> PreparedMapSnapshot {
        let trace = PerformanceTrace.begin("Build pin snapshots")
        defer { PerformanceTrace.end("Build pin snapshots", id: trace) }

        // A local decoder: the previous shared `static let` was used from several
        // detached tasks at once, and `JSONDecoder` is a non-Sendable class.
        let decoder = AppCoders.unitsDecoder()
        var pins: [UUID: MapPinSnapshot] = [:]
        pins.reserveCapacity(houses.count)
        var followUps = 0
        var joined = 0
        var open = 0
        var earlyNo = 0
        var lateNo = 0

        for house in houses where house.hasPlausibleCoordinate {
            let snapshot = pin(for: house, scope: scope, decoder: decoder)
            pins[house.id] = snapshot
            followUps += snapshot.followUpCount
            joined += snapshot.joinedCount
            open += snapshot.unitCount - snapshot.completedCount
            earlyNo += snapshot.earlyNoCount
            lateNo += snapshot.lateNoCount
        }

        return PreparedMapSnapshot(
            pinsByID: pins,
            stats: MapDayStats(
                houseCount: pins.count,
                followUpCount: followUps,
                joinedCount: joined,
                openCount: open,
                earlyNoCount: earlyNo,
                lateNoCount: lateNo
            ),
            bounds: MapBounds.around(pins.values.map(\.coordinate))
        )
    }

    /// Replaces the pins of houses that changed, leaving the rest untouched.
    static func patch(
        _ snapshot: PreparedMapSnapshot,
        with changed: [RawMapHouse],
        scope: DayScope
    ) -> PreparedMapSnapshot {
        let trace = PerformanceTrace.begin("Patch pin snapshots")
        defer { PerformanceTrace.end("Patch pin snapshots", id: trace) }

        let decoder = AppCoders.unitsDecoder()
        var pins = snapshot.pinsByID
        var followUps = snapshot.stats.followUpCount
        var joined = snapshot.stats.joinedCount
        var open = snapshot.stats.openCount
        var earlyNo = snapshot.stats.earlyNoCount
        var lateNo = snapshot.stats.lateNoCount
        var spatiallyChanged = false

        for house in changed {
            guard house.hasPlausibleCoordinate else {
                guard let previous = pins.removeValue(forKey: house.id) else { continue }
                followUps -= previous.followUpCount
                joined -= previous.joinedCount
                open -= previous.unitCount - previous.completedCount
                earlyNo -= previous.earlyNoCount
                lateNo -= previous.lateNoCount
                spatiallyChanged = true
                continue
            }
            let updated = pin(for: house, scope: scope, decoder: decoder)
            let previous = pins[house.id]
            if previous?.latitude != updated.latitude || previous?.longitude != updated.longitude {
                spatiallyChanged = true
            }
            pins[house.id] = updated
            followUps += updated.followUpCount - (previous?.followUpCount ?? 0)
            joined += updated.joinedCount - (previous?.joinedCount ?? 0)
            earlyNo += updated.earlyNoCount - (previous?.earlyNoCount ?? 0)
            lateNo += updated.lateNoCount - (previous?.lateNoCount ?? 0)
            let updatedOpen = updated.unitCount - updated.completedCount
            let previousOpen = previous.map { $0.unitCount - $0.completedCount } ?? 0
            open += updatedOpen - previousOpen
        }

        return PreparedMapSnapshot(
            pinsByID: pins,
            stats: MapDayStats(
                houseCount: pins.count,
                followUpCount: max(followUps, 0),
                joinedCount: max(joined, 0),
                openCount: max(open, 0),
                earlyNoCount: max(earlyNo, 0),
                lateNoCount: max(lateNo, 0)
            ),
            bounds: spatiallyChanged
                ? MapBounds.around(pins.values.map(\.coordinate))
                : snapshot.bounds
        )
    }

    static func pin(
        for house: RawMapHouse,
        scope: DayScope,
        decoder: JSONDecoder = AppCoders.unitsDecoder()
    ) -> MapPinSnapshot {
        // Decoding the real `DoorResult` — the old builder had a parallel
        // `LightweightDoor` type bridged by raw-string equality, so renaming a
        // `VisitOutcome` case would have silently dropped doors from the counts with
        // no compiler error anywhere.
        let doors = (try? decoder.decode([DoorResult].self, from: house.unitsData)) ?? []
        let tally = OutcomeTally.tally(doors, scope: scope)
        return MapPinSnapshot(
            id: house.id,
            address: house.address,
            latitude: house.latitude,
            longitude: house.longitude,
            markerOutcome: OutcomeTally.markerOutcome(for: doors, scope: scope),
            unitCount: doors.count,
            completedCount: tally.completed,
            followUpCount: tally.notHome,
            joinedCount: tally.joined,
            earlyNoCount: tally.earlyNo,
            lateNoCount: tally.lateNo
        )
    }
}
