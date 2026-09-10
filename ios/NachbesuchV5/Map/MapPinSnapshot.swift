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
    /// The pin remains present, but uses an explicit warning instead of pretending
    /// that unreadable door data means zero doors.
    let isDamaged: Bool
    /// Doors still needing a visit — straight from `OutcomeTally.open`, the one
    /// implementation of that question.
    ///
    /// It used to be derived here as `unitCount - completedCount`, which is a
    /// *different* number: that counts doors nobody has written on yet, while
    /// "offen" also includes the recorded ones that say come back — "Niemand da"
    /// and "Später". The map summary therefore reported 12 open where the list
    /// reported 40, for the same territory.
    let openCount: Int
    /// The earliest booked return time on this house, when a door is "Später".
    /// Carried on the pin so the map can offer the nearest open revisit.
    var nextRevisitAt: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Glyph baked into the pin bitmap: the outcome emoji for a single household,
    /// a progress counter for an apartment building.
    var markerText: String {
        if isDamaged { return "!" }
        if unitCount == 1 { return markerOutcome.displayEmojiRaw }
        // Riesige Zähler („1243/5871") würden je Haus eigene Bitmap-Varianten
        // erzeugen — ab 4 Stellen nur noch „>999". „12/124" bleibt lesbar.
        if unitCount > 999 || completedCount > 999 { return ">999" }
        return "\(completedCount)/\(unitCount)"
    }

    /// Same source as everything else that says "offen".
    ///
    /// The old spelling, `followUpCount > 0 || completedCount < unitCount`, silently
    /// excluded a house whose only outstanding door was a booked "Später": that door
    /// is recorded, so `completedCount == unitCount`, and it is not `notHome`, so
    /// `followUpCount` is 0. A house you had promised to return to at 18:00 counted
    /// as finished.
    var hasOpenWork: Bool { openCount > 0 }
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
    let damagedHouseCount: Int

    static let empty = MapDayStats(
        houseCount: 0, followUpCount: 0, joinedCount: 0,
        openCount: 0, earlyNoCount: 0, lateNoCount: 0, damagedHouseCount: 0
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
    /// When this row was last written. Carried so the map can advance a watermark
    /// and ask for only the houses touched since, rather than re-reading the
    /// territory after every door tap.
    let updatedAt: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        id: UUID,
        address: String,
        latitude: Double,
        longitude: Double,
        unitsData: Data,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.unitsData = unitsData
        self.updatedAt = updatedAt
    }

    @MainActor
    init(_ house: House) {
        self.init(
            id: house.id,
            address: house.address,
            latitude: house.latitude,
            longitude: house.longitude,
            unitsData: house.unitsData,
            updatedAt: house.updatedAt
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
        var damaged = 0

        for house in houses {
            let snapshot = pin(for: house, scope: scope, decoder: decoder)
            pins[house.id] = snapshot
            followUps += snapshot.followUpCount
            joined += snapshot.joinedCount
            open += snapshot.openCount
            earlyNo += snapshot.earlyNoCount
            lateNo += snapshot.lateNoCount
            if snapshot.isDamaged { damaged += 1 }
        }

        return PreparedMapSnapshot(
            pinsByID: pins,
            stats: MapDayStats(
                houseCount: houses.count,
                followUpCount: followUps,
                joinedCount: joined,
                openCount: open,
                earlyNoCount: earlyNo,
                lateNoCount: lateNo,
                damagedHouseCount: damaged
            ),
            bounds: MapBounds.around(houses.map(\.coordinate))
        )
    }

    /// Inserts new pins and replaces pins of houses that changed, leaving the rest
    /// untouched. New houses use this path immediately after a successful save, so
    /// their annotation does not have to wait for the asynchronous store refresh.
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
        var damaged = snapshot.stats.damagedHouseCount

        for house in changed {
            let updated = pin(for: house, scope: scope, decoder: decoder)
            let previous = pins[house.id]
            pins[house.id] = updated
            followUps += updated.followUpCount - (previous?.followUpCount ?? 0)
            joined += updated.joinedCount - (previous?.joinedCount ?? 0)
            earlyNo += updated.earlyNoCount - (previous?.earlyNoCount ?? 0)
            lateNo += updated.lateNoCount - (previous?.lateNoCount ?? 0)
            open += updated.openCount - (previous?.openCount ?? 0)
            damaged += (updated.isDamaged ? 1 : 0) - (previous?.isDamaged == true ? 1 : 0)
        }

        let insertedPin = changed.contains { snapshot.pinsByID[$0.id] == nil }
        return PreparedMapSnapshot(
            pinsByID: pins,
            stats: MapDayStats(
                houseCount: pins.count,
                followUpCount: max(followUps, 0),
                joinedCount: max(joined, 0),
                openCount: max(open, 0),
                earlyNoCount: max(earlyNo, 0),
                lateNoCount: max(lateNo, 0),
                damagedHouseCount: max(damaged, 0)
            ),
            // Existing pins do not move through this path. An insertion can extend
            // the territory, so only that less-common case recomputes the extent.
            bounds: insertedPin
                ? MapBounds.around(pins.values.map(\.coordinate))
                : snapshot.bounds
        )
    }

    /// Drops deleted houses, the mirror of `patch` for inserts. Deletions never
    /// appear in the watermark fetch — a deleted row comes back in no query —
    /// so without this the pins lingered until the next full rebuild.
    static func removing(_ snapshot: PreparedMapSnapshot, ids: Set<UUID>) -> PreparedMapSnapshot {
        guard !ids.isEmpty else { return snapshot }
        var pins = snapshot.pinsByID
        var followUps = snapshot.stats.followUpCount
        var joined = snapshot.stats.joinedCount
        var open = snapshot.stats.openCount
        var earlyNo = snapshot.stats.earlyNoCount
        var lateNo = snapshot.stats.lateNoCount
        var damaged = snapshot.stats.damagedHouseCount

        for id in ids {
            guard let previous = pins.removeValue(forKey: id) else { continue }
            followUps -= previous.followUpCount
            joined -= previous.joinedCount
            earlyNo -= previous.earlyNoCount
            lateNo -= previous.lateNoCount
            open -= previous.openCount
            damaged -= previous.isDamaged ? 1 : 0
        }

        return PreparedMapSnapshot(
            pinsByID: pins,
            stats: MapDayStats(
                houseCount: pins.count,
                followUpCount: max(followUps, 0),
                joinedCount: max(joined, 0),
                openCount: max(open, 0),
                earlyNoCount: max(earlyNo, 0),
                lateNoCount: max(lateNo, 0),
                damagedHouseCount: max(damaged, 0)
            ),
            // A deletion can shrink the extent, so unlike the patch path this
            // always remeasures. Coordinates only, no decoding.
            bounds: MapBounds.around(pins.values.map(\.coordinate))
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
        let state = HouseDataState.decode(house.unitsData, decoder: decoder)
        let doors = state.doors ?? []
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
            lateNoCount: tally.lateNo,
            isDamaged: state.isDamaged,
            openCount: tally.open,
            nextRevisitAt: doors.compactMap { $0.displayRevisitAt(in: scope) }.min()
        )
    }
}
