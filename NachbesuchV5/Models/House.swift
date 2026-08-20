import CoreLocation
import Foundation
import SwiftData

/// One address on the map. A single-family house has exactly one door; an apartment
/// building has many.
///
/// **Stored shape is frozen.** Every property below matches what shipped, byte for
/// byte, because the app has no schema migration history and a mismatched store
/// means an unopenable database. Fixes live in behaviour, not in storage.
@Model
final class House {
    @Attribute(.unique) var id: UUID
    var address: String
    var note: String
    var latitude: Double
    var longitude: Double
    var isApartmentBuilding: Bool
    var gebietID: UUID?
    /// Legacy twin of `gebietID`, always written to the same value. Kept only
    /// because dropping a property needs a migration; read through `territoryID`.
    var dayID: UUID?
    var unitsData: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        address: String,
        latitude: Double,
        longitude: Double,
        gebietID: UUID,
        isApartmentBuilding: Bool,
        unitCount: Int,
        unitsData: Data? = nil
    ) {
        id = UUID()
        self.address = address
        note = ""
        self.latitude = latitude
        self.longitude = longitude
        self.gebietID = gebietID
        dayID = gebietID
        self.isApartmentBuilding = isApartmentBuilding
        if let unitsData {
            // Bulk paths (backup restore) already hold encoded doors; encoding a
            // throwaway placeholder first would be pure waste at import scale.
            self.unitsData = unitsData
        } else {
            let count = isApartmentBuilding ? max(2, unitCount) : 1
            let doors = (1...count).map {
                DoorResult(label: isApartmentBuilding ? "Tür \($0)" : "Haushalt")
            }
            self.unitsData = (try? AppCoders.unitsEncoder().encode(doors)) ?? Data()
        }
        createdAt = .now
        updatedAt = .now
    }

    /// The territory this house belongs to, tolerating pre-migration rows that only
    /// ever had the legacy key.
    var territoryID: UUID? { gebietID ?? dayID }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: - Doors

    /// Decoded doors, or `nil` when the stored blob cannot be read.
    ///
    /// Returning `nil` rather than `[]` matters: every mutation below refuses to run
    /// on an unreadable blob, so a transient decode failure can never be converted
    /// into permanent data loss by overwriting it with an empty array.
    func decodedUnits() -> [DoorResult]? {
        if unitsData.isEmpty { return [] }
        return try? AppCoders.unitsDecoder().decode([DoorResult].self, from: unitsData)
    }

    var units: [DoorResult] { decodedUnits() ?? [] }

    /// True when the stored doors are unreadable — surfaced in the UI instead of
    /// silently showing a house with zero households.
    var isDamaged: Bool { !unitsData.isEmpty && decodedUnits() == nil }

    func summary(for scope: DayScope = .combined) -> HouseSummary {
        HouseSummary(units: units, scope: scope)
    }

    /// The one place doors are written. Refuses to encode over an unreadable blob
    /// and always moves `updatedAt` forward, never backward.
    @discardableResult
    private func writeUnits(_ newUnits: [DoorResult]) -> Bool {
        guard let encoded = try? AppCoders.unitsEncoder().encode(newUnits) else { return false }
        unitsData = encoded
        touch()
        return true
    }

    /// `updatedAt` is the change signal every snapshot, index and export task keys
    /// off. It must be monotonic: rewinding it (as undo used to) leaves those caches
    /// convinced they are current while showing stale data.
    func touch() {
        let now = Date.now
        updatedAt = now > updatedAt ? now : updatedAt.addingTimeInterval(0.001)
    }

    // MARK: - Mutations

    func setOutcome(_ outcome: VisitOutcome?, for unitID: UUID, day: Int) {
        guard var copy = decodedUnits(),
              let index = copy.firstIndex(where: { $0.id == unitID }) else { return }
        if day == 2 {
            copy[index].day2Outcome = outcome
            copy[index].day2UpdatedAt = outcome == nil ? nil : .now
        } else {
            copy[index].outcome = outcome
            copy[index].updatedAt = outcome == nil ? nil : .now
        }
        writeUnits(copy)
    }

    /// Fills in every door that still counts as open on the given day.
    ///
    /// On day 2 that means doors awaiting a revisit — the ones the second day exists
    /// for. The old implementation asked `outcome(for: 2)`, which fell back to the
    /// day-1 value and therefore skipped exactly those doors.
    @discardableResult
    func setOutcomeForOpenDoors(_ outcome: VisitOutcome, day: Int) -> Int {
        guard var copy = decodedUnits() else { return 0 }
        let scope: DayScope = day == 2 ? .day2 : .day1
        var changed = 0
        for index in copy.indices where copy[index].isOpen(in: scope) {
            if day == 2 {
                copy[index].day2Outcome = outcome
                copy[index].day2UpdatedAt = .now
            } else {
                copy[index].outcome = outcome
                copy[index].updatedAt = .now
            }
            changed += 1
        }
        guard changed > 0, writeUnits(copy) else { return 0 }
        return changed
    }

    func renameUnit(_ name: String, id unitID: UUID) {
        guard var copy = decodedUnits(),
              let index = copy.firstIndex(where: { $0.id == unitID }) else { return }
        copy[index].label = name
        writeUnits(copy)
    }

    /// Restores a previous door state for undo.
    ///
    /// Undo is a change like any other, so `updatedAt` moves **forward**. Rewinding
    /// it used to drop the house out of the map's "changed since" window, leaving
    /// the pin showing the status the user had just undone.
    func restore(units previousUnits: [DoorResult]) {
        writeUnits(previousUnits)
    }

    func convertToApartmentBuilding(unitCount: Int) {
        guard !isApartmentBuilding, var copy = decodedUnits() else { return }
        let target = max(2, unitCount)
        if copy.isEmpty {
            copy.append(DoorResult(label: "Tür 1"))
        } else {
            copy[0].label = "Tür 1"
        }
        while copy.count < target {
            copy.append(DoorResult(label: "Tür \(copy.count + 1)"))
        }
        isApartmentBuilding = true
        writeUnits(copy)
    }

    func resizeUnits(to unitCount: Int) {
        guard var copy = decodedUnits() else { return }
        let target = min(max(unitCount, 2), 100)
        guard copy.count != target else { return }
        if copy.count < target {
            while copy.count < target {
                copy.append(DoorResult(label: "Tür \(copy.count + 1)"))
            }
        } else {
            copy.removeLast(copy.count - target)
        }
        isApartmentBuilding = true
        writeUnits(copy)
    }

    /// Replaces the encoded doors wholesale (backup restore). Goes through the same
    /// funnel so `updatedAt` cannot be left behind.
    func replaceUnitsData(_ data: Data) {
        unitsData = data
        touch()
    }
}
