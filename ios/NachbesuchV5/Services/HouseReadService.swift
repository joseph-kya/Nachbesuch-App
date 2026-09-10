import Foundation
import SwiftData

/// Listen-Seed plus Änderungssignal: Die Liste kann damit per Watermark nur die
/// Häuser neu aufbauen, die sich seit der letzten Momentaufnahme geändert haben.
nonisolated struct HouseListDelta: Sendable, Equatable {
    let seed: HouseListBuilder.Seed
    let updatedAt: Date
}

/// Harte Grenze für Export-/Backup-Lesungen: schützt vor pathologischen Stores
/// (z. B. versehentlich riesige Importe). Analog zu
/// `AreaHouseImportError.tooManyResults` beim Gebietsimport.
nonisolated enum HouseReadError: LocalizedError {
    case tooManyResults(limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyResults(let limit):
            "Der Export umfasst mehr als \(limit) Einträge. Teile den Bestand bitte in kleinere Runden."
        }
    }
}

/// Reads large house collections on a private SwiftData actor and returns immutable
/// value snapshots. UI bodies must never materialise thousands of live `House`
/// models on the main actor merely to construct list or archive presentation data.
@ModelActor
actor HouseReadService {
    /// Harte Obergrenze pro Export-/Backup-Lauf. Weit über jedem echten Gebiet,
    /// aber endlich: ohne Deckel baut ein pathologischer Store ein ID-Array ohne
    /// Ende, das danach auf Main nachgezogen würde.
    static let fetchBatchLimit = 10_000

    /// Zählt einen Export-/Backup-Lauf mit und wirft jenseits von
    /// `fetchBatchLimit` — wiederverwendbar für Backup-Pfade außerhalb dieses
    /// Actors (reine Zählprüfung, kein Store-Zugriff).
    nonisolated static func checkFetchBatch(_ count: Int) throws {
        if count > fetchBatchLimit {
            throw HouseReadError.tooManyResults(limit: fetchBatchLimit)
        }
    }

    /// SwiftData chooses the context executor at initialization. Create it away
    /// from MainActor; an actor declaration alone does not move its context.
    nonisolated static func background(container: ModelContainer) async -> HouseReadService {
        await Task.detached(priority: Task.currentPriority) {
            HouseReadService(modelContainer: container)
        }.value
    }

    /// Seed-Zeilen eines Gebiets für die Liste. Bewusst ohne `sortBy`: Die Liste
    /// sortiert downstream selbst (offene zuerst, Entfernung, Uhrzeit), eine
    /// DB-Sortierung wäre weggeworfene Arbeit auf 5 000 Zeilen. Strom per
    /// Enumerate statt Fetch-Array, Abbruch alle 64 Zeilen.
    func listSeeds(territoryID: UUID) throws -> [HouseListBuilder.Seed] {
        let descriptor = FetchDescriptor<House>(
            predicate: #Predicate {
                $0.gebietID == territoryID || $0.dayID == territoryID
            }
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

    /// Watermark-Variante für `didSave`-Filterung: Ohne Datum volle Seeds wie
    /// oben, mit Datum nur Häuser ab der letzten Momentaufnahme. Die Liste kann
    /// damit Inhaltsänderungen patchen statt das ganze Gebiet neu zu lesen —
    /// Aufrufer-Übernahme optional, kein bestehender Pfad ändert sich.
    func listSeeds(territoryID: UUID, updatedAfter: Date?) throws -> [HouseListDelta] {
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
        var result: [HouseListDelta] = []
        var visited = 0
        try modelContext.enumerate(descriptor, batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(
                HouseListDelta(
                    seed: HouseListBuilder.Seed(
                        id: house.id,
                        address: house.address,
                        note: house.note,
                        createdAt: house.createdAt,
                        unitsData: house.unitsData,
                        latitude: house.latitude,
                        longitude: house.longitude
                    ),
                    updatedAt: house.updatedAt
                )
            )
        }
        return result
    }

    /// IDs for one territory's export. The list resolves them to live models on
    /// the main actor behind a spinner — the tap itself never pays for a
    /// thousand-object fault storm, and no door blob is decoded here.
    func exportIDs(territoryID: UUID) throws -> (houses: [UUID], passanten: [UUID]) {
        var houses: [UUID] = []
        var passanten: [UUID] = []
        var visited = 0
        try modelContext.enumerate(
            FetchDescriptor<House>(predicate: #Predicate {
                $0.gebietID == territoryID || $0.dayID == territoryID
            }),
            batchSize: 200
        ) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            houses.append(house.id)
            // Deckel gegen pathologische Stores (siehe `fetchBatchLimit`).
            try Self.checkFetchBatch(houses.count)
        }
        try modelContext.enumerate(
            FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == territoryID }),
            batchSize: 200
        ) { passant in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            passanten.append(passant.id)
            try Self.checkFetchBatch(passanten.count)
        }
        return (houses, passanten)
    }

    /// Nur Passanten-IDs eines Gebiets, ohne Blobs und Koordinaten — für Pfade,
    /// die nur wissen müssen, *welche* Begegnungen dazugehören, und die Modelle
    /// danach per ID auf Main nachziehen (wie `exportIDs` für Häuser).
    func passantIDs(territoryID: UUID) throws -> [UUID] {
        var result: [UUID] = []
        var visited = 0
        try modelContext.enumerate(
            FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == territoryID }),
            batchSize: 200
        ) { passant in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(passant.id)
            // Gleicher Deckel wie `exportIDs` — reiner ID-Lauf ohne Blobs.
            try Self.checkFetchBatch(result.count)
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
        // Reconciliation replaces every revisit notification, including street
        // encounters. Use the same identity as their immediate scheduling path.
        try modelContext.enumerate(FetchDescriptor<Passant>(), batchSize: 200) { passant in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            guard passant.outcome == .later, let date = passant.revisitAt else { return }
            result.append(.init(
                houseID: passant.id, doorID: passant.id, day: 1,
                address: passant.note, doorLabel: "Gespräch",
                isApartmentBuilding: false, date: date
            ))
        }
        return result
    }

    /// Pin inputs for one territory. A nil watermark performs a full read;
    /// otherwise only houses changed since the last snapshot are returned.
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
