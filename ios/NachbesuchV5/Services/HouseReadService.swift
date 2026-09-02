import Foundation
import SwiftData

/// Reads large house collections on a private SwiftData actor and returns immutable
/// value snapshots. UI bodies must never materialise thousands of live `House`
/// models on the main actor merely to construct list or archive presentation data.
@ModelActor
actor HouseReadService {
    func listSeeds(territoryID: UUID) throws -> [HouseListBuilder.Seed] {
        let descriptor = FetchDescriptor<House>(
            predicate: #Predicate {
                $0.gebietID == territoryID || $0.dayID == territoryID
            },
            sortBy: [SortDescriptor(\House.createdAt, order: .reverse)]
        )
        var result: [HouseListBuilder.Seed] = []
        var visited = 0
        try modelContext.enumerate(descriptor, batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(
                HouseListBuilder.Seed(
                    id: house.id,
                    address: house.address,
                    note: house.note,
                    createdAt: house.createdAt,
                    unitsData: house.unitsData,
                    latitude: house.latitude,
                    longitude: house.longitude
                )
            )
        }
        return result
    }

    func archiveSeeds() throws -> [ArchiveIndexBuilder.HouseSeed] {
        var result: [ArchiveIndexBuilder.HouseSeed] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<House>(), batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(
                ArchiveIndexBuilder.HouseSeed(
                    gebietID: house.territoryID,
                    address: house.address,
                    note: house.note,
                    unitsData: house.unitsData
                )
            )
        }
        return result
    }

    /// Address + coordinate fingerprints for one territory's duplicate checks —
    /// the manual add sheet and the bulk importer. Both open from menus, so this
    /// read must not sit in the presentation transaction on the main actor: a
    /// full fetch of live models plus per-address normalisation is what made
    /// those sheets stutter open on large territories.
    func addressFingerprints(territoryID: UUID) throws -> [ExistingHouseFingerprint] {
        let descriptor = FetchDescriptor<House>(predicate: #Predicate {
            $0.gebietID == territoryID || $0.dayID == territoryID
        })
        var result: [ExistingHouseFingerprint] = []
        var visited = 0
        try modelContext.enumerate(descriptor, batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(
                ExistingHouseFingerprint(
                    address: house.address,
                    latitude: house.latitude,
                    longitude: house.longitude
                )
            )
        }
        return result
    }

    /// Pin inputs for one territory.
    ///
    /// `updatedAfter` is what makes a door tap cheap: the map keeps a watermark of
    /// the newest row it drew, and asks for only what has been written since. A full
    /// read (`nil`) happens on a territory switch or a first load.
    /// Every booked return time in the store.
    ///
    /// A revisit lives inside `unitsData`, a JSON blob, so no predicate can narrow
    /// this — the whole store has to be walked and decoded. That is precisely why it
    /// must not happen on the main actor: it used to run there after every save, so
    /// each door tap in the field bought a full decode of the territory 600 ms later,
    /// on the thread drawing the next screen.
    func revisitCandidates() throws -> [RevisitReminderCandidate] {
        var result: [RevisitReminderCandidate] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<House>(), batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            guard let doors = house.decodedUnits() else { return }
            for door in doors {
                if door.outcome == .later, let date = door.revisitAt {
                    result.append(.init(
                        houseID: house.id, doorID: door.id, day: 1,
                        address: house.address, doorLabel: door.label,
                        isApartmentBuilding: house.isApartmentBuilding, date: date
                    ))
                }
                if door.day2Outcome == .later, let date = door.day2RevisitAt {
                    result.append(.init(
                        houseID: house.id, doorID: door.id, day: 2,
                        address: house.address, doorLabel: door.label,
                        isApartmentBuilding: house.isApartmentBuilding, date: date
                    ))
                }
            }
        }
        return result
    }

    func mapSeeds(territoryID: UUID, updatedAfter: Date?) throws -> [RawMapHouse] {
        let descriptor: FetchDescriptor<House>
        if let updatedAfter {
            descriptor = FetchDescriptor<House>(
                predicate: #Predicate {
                    ($0.gebietID == territoryID || $0.dayID == territoryID)
                        && $0.updatedAt > updatedAfter
                }
            )
        } else {
            descriptor = FetchDescriptor<House>(
                predicate: #Predicate {
                    $0.gebietID == territoryID || $0.dayID == territoryID
                }
            )
        }
        var result: [RawMapHouse] = []
        var visited = 0
        try modelContext.enumerate(descriptor, batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(
                RawMapHouse(
                    id: house.id,
                    address: house.address,
                    latitude: house.latitude,
                    longitude: house.longitude,
                    unitsData: house.unitsData,
                    updatedAt: house.updatedAt
                )
            )
        }
        return result
    }
}

/// Runs `work` off the main actor and hands it the caller's cancellation.
///
/// `await Task.detached { … }.value` does not do that on its own: awaiting a
/// detached task does not cancel it, so a screen left mid-build keeps a core busy
/// finishing a snapshot nobody will read. Under rapid tab switching those orphans
/// stack — which is how one flick along the tab bar ended up with six threads all
/// decoding the same territory at once. The work still has to *check*
/// `Task.isCancelled` to stop early; this is what makes the flag reach it.
func offMainActor<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ work: @escaping @Sendable () -> T
) async -> T {
    let task = Task.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}
