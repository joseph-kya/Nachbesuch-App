import Foundation
import SwiftData

nonisolated struct AppBackup: Codable, Sendable {
    let formatVersion: Int
    let exportedAt: Date
    let gebiete: [BackupGebiet]
    let houses: [BackupHouse]
    /// Street encounters (SchemaV2). Missing in v2 files — then it decodes as
    /// empty rather than failing, so every old backup still restores.
    let passanten: [BackupPassant]

    enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, gebiete, houses, passanten
    }

    init(formatVersion: Int, exportedAt: Date, gebiete: [BackupGebiet], houses: [BackupHouse], passanten: [BackupPassant]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.gebiete = gebiete
        self.houses = houses
        self.passanten = passanten
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        gebiete = try container.decode([BackupGebiet].self, forKey: .gebiete)
        houses = try container.decode([BackupHouse].self, forKey: .houses)
        passanten = try container.decodeIfPresent([BackupPassant].self, forKey: .passanten) ?? []
    }
}

nonisolated struct BackupGebiet: Codable, Sendable {
    let id: UUID
    let name: String
    let districtOrCity: String
    let notes: String
    let isTwoDay: Bool
    let day1Date: Date
    let day2Date: Date?
    let boundaryData: Data
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct BackupHouse: Codable, Sendable {
    let id: UUID
    let address: String
    let note: String
    let latitude: Double
    let longitude: Double
    let isApartmentBuilding: Bool
    let gebietID: UUID?
    let dayID: UUID?
    let units: [DoorResult]
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct BackupPassant: Codable, Sendable {
    let id: UUID
    let note: String
    let latitude: Double
    let longitude: Double
    let outcome: VisitOutcome?
    let revisitAt: Date?
    let gebietID: UUID?
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct BackupImportResult: Sendable {
    let importedGebiete: Int
    let importedHouses: Int
    let importedPassanten: Int
    let skippedHouses: Int
}

// Legacy v1 format structures for backward compatibility.
// Internal (not private) so the importer test can build a v1 fixture from
// the exact structs the reader decodes — never a second description of them.
nonisolated struct LegacyAppBackup: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let days: [LegacyBackupDay]
    let houses: [LegacyBackupHouse]
}

nonisolated struct LegacyBackupDay: Codable {
    let id: UUID
    let date: Date
    let createdAt: Date
    let boundaryData: Data
}

nonisolated struct LegacyBackupHouse: Codable {
    let id: UUID
    let address: String
    let note: String
    let latitude: Double
    let longitude: Double
    let isApartmentBuilding: Bool
    let dayID: UUID?
    let units: [DoorResult]
    let createdAt: Date
    let updatedAt: Date
}

@MainActor
enum BackupService {
    /// Sendable raw copies: the JSON work (units decode/encode, container encoding,
    /// file writes) runs off the main thread so the UI never blocks on a backup.
    nonisolated struct GebietSnapshot: Sendable {
        let id: UUID
        let name: String
        let districtOrCity: String
        let notes: String
        let isTwoDay: Bool
        let day1Date: Date
        let day2Date: Date?
        let boundaryData: Data
        let createdAt: Date
        let updatedAt: Date

        init(_ gebiet: Gebiet) {
            id = gebiet.id
            name = gebiet.name
            districtOrCity = gebiet.districtOrCity
            notes = gebiet.notes
            isTwoDay = gebiet.isTwoDay
            day1Date = gebiet.day1Date
            day2Date = gebiet.day2Date
            boundaryData = gebiet.boundaryData
            createdAt = gebiet.createdAt
            updatedAt = gebiet.updatedAt
        }
    }

    nonisolated struct HouseSnapshot: Sendable {
        let id: UUID
        let address: String
        let note: String
        let latitude: Double
        let longitude: Double
        let isApartmentBuilding: Bool
        let gebietID: UUID?
        let dayID: UUID?
        let unitsData: Data
        let createdAt: Date
        let updatedAt: Date

        init(_ house: House) {
            id = house.id
            address = house.address
            note = house.note
            latitude = house.latitude
            longitude = house.longitude
            isApartmentBuilding = house.isApartmentBuilding
            gebietID = house.gebietID ?? house.dayID
            dayID = house.dayID
            unitsData = house.unitsData
            createdAt = house.createdAt
            updatedAt = house.updatedAt
        }
    }

    nonisolated struct PassantSnapshot: Sendable {
        let id: UUID
        let note: String
        let latitude: Double
        let longitude: Double
        let outcome: VisitOutcome?
        let revisitAt: Date?
        let gebietID: UUID?
        let createdAt: Date
        let updatedAt: Date

        init(_ passant: Passant) {
            id = passant.id
            note = passant.note
            latitude = passant.latitude
            longitude = passant.longitude
            outcome = passant.outcome
            revisitAt = passant.revisitAt
            gebietID = passant.gebietID
            createdAt = passant.createdAt
            updatedAt = passant.updatedAt
        }
    }

    /// The archive's complete-store entry point. Reads must succeed before any
    /// file is written; a failed fetch is never an empty collection to back up.
    /// Snapshots entstehen im Hintergrund-Actor per Enumerate (wie AutoBackup),
    /// nie als Voll-Fetch auf Main — sonst friert der Export bei 5 000 Häusern.
    static func makeBackup(in modelContext: ModelContext) async throws -> URL {
        let reader = await BackupSnapshotReader.background(container: modelContext.container)
        let gebietSnapshots = try await reader.fetchGebietSnapshots()
        let houseSnapshots = try await reader.fetchHouseSnapshots()
        let passantSnapshots = try await reader.fetchPassantSnapshots()
        let data = try await encodeBackup(
            gebietSnapshots: gebietSnapshots,
            houseSnapshots: houseSnapshots,
            passantSnapshots: passantSnapshots
        )
        return try await Task.detached(priority: .userInitiated) { () -> URL in
            let date = Date.now.formatted(.iso8601.year().month().day())
            let url = try ExportScratch.makeURL(fileName: "Nachbesuch-Backup-\(date).json")
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    /// The backup as bytes, without choosing where they land. The manual export
    /// writes them to the share scratch directory; the automatic safety backup
    /// writes them into the Files-visible documents directory.
    /// Priorität wählbar wie in `encodeBackup`: manuell `.userInitiated`,
    /// automatisch `.background` — kein Encode läuft je auf Main.
    static func makeBackupData(
        gebiete: [Gebiet],
        houses: [House],
        passanten: [Passant] = [],
        priority: TaskPriority = .userInitiated
    ) async throws -> Data {
        let trace = PerformanceTrace.begin("Create backup")
        defer { PerformanceTrace.end("Create backup", id: trace) }

        let gebietSnapshots = gebiete.map(GebietSnapshot.init)
        let houseSnapshots = houses.map(HouseSnapshot.init)
        let passantSnapshots = passanten.map(PassantSnapshot.init)
        return try await encodeBackup(
            gebietSnapshots: gebietSnapshots,
            houseSnapshots: houseSnapshots,
            passantSnapshots: passantSnapshots,
            priority: priority
        )
    }

    /// Encode already-detached snapshots. Internal so the automatic backup can
    /// snapshot on its own background context and share this exact encoder —
    /// never a second serialiser. Priorität wählbar: manuell userInitiated,
    /// automatisch background — sonst gewinnt die Sicherung CPU gegen Pins.
    static func encodeBackup(
        gebietSnapshots: [GebietSnapshot],
        houseSnapshots: [HouseSnapshot],
        passantSnapshots: [PassantSnapshot] = [],
        priority: TaskPriority = .userInitiated
    ) async throws -> Data {
        try await Task.detached(priority: priority) { () -> Data in
            let decoder = AppCoders.unitsDecoder()
            let backup = AppBackup(
                formatVersion: 3,
                exportedAt: .now,
                gebiete: gebietSnapshots.map { snapshot in
                    BackupGebiet(
                        id: snapshot.id,
                        name: snapshot.name,
                        districtOrCity: snapshot.districtOrCity,
                        notes: snapshot.notes,
                        isTwoDay: snapshot.isTwoDay,
                        day1Date: snapshot.day1Date,
                        day2Date: snapshot.day2Date,
                        boundaryData: snapshot.boundaryData,
                        createdAt: snapshot.createdAt,
                        updatedAt: snapshot.updatedAt
                    )
                },
                houses: try houseSnapshots.map { snapshot in
                    // A house whose doors cannot be decoded must ABORT the backup.
                    // Writing it with zero units silently discarded exactly the data
                    // the backup exists to protect — and the user would only find out
                    // when restoring after losing the device.
                    let units: [DoorResult]
                    if snapshot.unitsData.isEmpty {
                        units = []
                    } else {
                        do {
                            units = try decoder.decode([DoorResult].self, from: snapshot.unitsData)
                        } catch {
                            throw BackupError.unreadableHouse(address: snapshot.address)
                        }
                    }
                    return BackupHouse(
                        id: snapshot.id,
                        address: snapshot.address,
                        note: snapshot.note,
                        latitude: snapshot.latitude,
                        longitude: snapshot.longitude,
                        isApartmentBuilding: snapshot.isApartmentBuilding,
                        gebietID: snapshot.gebietID,
                        dayID: snapshot.dayID,
                        units: units,
                        createdAt: snapshot.createdAt,
                        updatedAt: snapshot.updatedAt
                    )
                },
                passanten: passantSnapshots.map { snapshot in
                    BackupPassant(
                        id: snapshot.id,
                        note: snapshot.note,
                        latitude: snapshot.latitude,
                        longitude: snapshot.longitude,
                        outcome: snapshot.outcome,
                        revisitAt: snapshot.revisitAt,
                        gebietID: snapshot.gebietID,
                        createdAt: snapshot.createdAt,
                        updatedAt: snapshot.updatedAt
                    )
                }
            )

            return try AppCoders.backupEncoder().encode(backup)
        }.value
    }

    nonisolated static func readBackup(at url: URL) async throws -> AppBackup {
        try await readBackup(from: url)
    }

    nonisolated static func readBackup(from url: URL) async throws -> AppBackup {
        try await Task.detached(priority: .userInitiated) {
            try readBackupSynchronously(from: url)
        }.value
    }

    private nonisolated struct VersionProbe: Decodable {
        let formatVersion: Int
    }

    private nonisolated static func readBackupSynchronously(from url: URL) throws -> AppBackup {
        // Security-scoped: files chosen through the document picker are outside the
        // sandbox until access is explicitly started.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let decoder = AppCoders.backupDecoder()

        // Probe the version FIRST. Both decodes used to be `try?`, so a truncated
        // file, a wrong encoding and a genuinely newer format all reported
        // "Version 0" — actively misleading someone restoring after a device loss.
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw BackupError.unreadableFile
        }

        switch probe.formatVersion {
        case 2, 3:
            do {
                // v2 files carry no `passanten` key; the custom decoder fills
                // them as empty rather than failing, so every old backup still
                // restores.
                return try decoder.decode(AppBackup.self, from: data)
            } catch {
                throw BackupError.corruptContents(underlying: error)
            }
        case 1:
            break
        default:
            throw BackupError.unsupportedVersion(probe.formatVersion)
        }

        // Legacy v1 format, translated forward.
        if let v1Backup = try? decoder.decode(LegacyAppBackup.self, from: data) {
            let gebiete = v1Backup.days.map { day in
                BackupGebiet(
                    id: day.id,
                    name: "Gebiet vom \(day.date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "de_AT"))))",
                    districtOrCity: "",
                    notes: "",
                    isTwoDay: false,
                    day1Date: day.date,
                    day2Date: nil,
                    boundaryData: day.boundaryData,
                    createdAt: day.createdAt,
                    updatedAt: day.createdAt
                )
            }
            let houses = v1Backup.houses.map { house in
                BackupHouse(
                    id: house.id,
                    address: house.address,
                    note: house.note,
                    latitude: house.latitude,
                    longitude: house.longitude,
                    isApartmentBuilding: house.isApartmentBuilding,
                    gebietID: house.dayID,
                    dayID: house.dayID,
                    units: house.units,
                    createdAt: house.createdAt,
                    updatedAt: house.updatedAt
                )
            }
            return AppBackup(formatVersion: 2, exportedAt: v1Backup.exportedAt, gebiete: gebiete, houses: houses, passanten: [])
        }

        throw BackupError.corruptContents(underlying: nil)
    }

    static func importBackup(
        _ backup: AppBackup,
        into modelContext: ModelContext
    ) async throws -> BackupImportResult {
        // Komplett im Hintergrund-Actor (BulkHouseImporter-Muster): kein Voll-Fetch
        // und keine 5 000 Inserts auf Main — sonst friert der Import ein.
        let importer = await BackupImportActor.background(container: modelContext.container)
        do {
            return try await importer.performImport(backup)
        } catch {
            // Ohne das bleibt ein halber Import im Main-Kontext und wird beim
            // nächsten fremden Save still mitgeschrieben.
            modelContext.rollback()
            if let backupError = error as? BackupError {
                throw backupError
            }
            throw BackupError.storeUnavailable(underlying: error)
        }
    }

}

/// Snapshots per Enumerate im Hintergrund — gleiche Technik wie AutoBackup,
/// damit der Export nie den Main-Thread mit Voll-Fetch blockiert.
@ModelActor
actor BackupSnapshotReader {
    nonisolated static func background(container: ModelContainer) async -> BackupSnapshotReader {
        await Task.detached(priority: .background) {
            BackupSnapshotReader(modelContainer: container)
        }.value
    }

    func fetchGebietSnapshots() throws -> [BackupService.GebietSnapshot] {
        var result: [BackupService.GebietSnapshot] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<Gebiet>(), batchSize: 200) { gebiet in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(BackupService.GebietSnapshot(gebiet))
        }
        return result
    }

    func fetchHouseSnapshots() throws -> [BackupService.HouseSnapshot] {
        var result: [BackupService.HouseSnapshot] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<House>(), batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(BackupService.HouseSnapshot(house))
        }
        return result
    }

    func fetchPassantSnapshots() throws -> [BackupService.PassantSnapshot] {
        var result: [BackupService.PassantSnapshot] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<Passant>(), batchSize: 200) { passant in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(BackupService.PassantSnapshot(passant))
        }
        return result
    }
}

/// Import in Batches auf Hintergrund-Kontext (BulkHouseImporter-Muster):
/// Autosave aus, 400er-Chargen, vorcodierte Tür-Blobs — sonst 5 000 Inserts
/// auf Main und ein riesiger Einzel-Save.
/// Nutzt den Bulk-Importer bewusst nicht direkt: Der legt identische
/// Platzhalter-Türen für ein einziges Gebiet an, hier trägt jedes Haus eigene
/// Türen, braucht Gebiets-Remap plus Dedupe. Das Batch-Protokoll (Autosave aus,
/// 400er-Chargen, vorcodierte Blobs) ist dasselbe — geprüft, keine Lücke.
@ModelActor
actor BackupImportActor {
    private static let batchSize = 400

    nonisolated static func background(container: ModelContainer) async -> BackupImportActor {
        await Task.detached(priority: .background) {
            BackupImportActor(modelContainer: container)
        }.value
    }

    func performImport(_ backup: AppBackup) throws -> BackupImportResult {
        let trace = PerformanceTrace.begin("Import backup")
        defer { PerformanceTrace.end("Import backup", id: trace) }
        modelContext.autosaveEnabled = false

        // Bestand per Enumerate im Hintergrund — keine Voll-Fetches auf Main.
        var gebieteByID: [UUID: Gebiet] = [:]
        var visited = 0
        do {
            try modelContext.enumerate(FetchDescriptor<Gebiet>(), batchSize: 200) { gebiet in
                if visited.isMultiple(of: 64) { try Task.checkCancellation() }
                visited += 1
                gebieteByID[gebiet.id] = gebieteByID[gebiet.id] ?? gebiet
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackupError.storeUnavailable(underlying: error)
        }
        var existingHouseIDs = Set<UUID>()
        do {
            try modelContext.enumerate(FetchDescriptor<House>(), batchSize: 200) { house in
                if visited.isMultiple(of: 64) { try Task.checkCancellation() }
                visited += 1
                existingHouseIDs.insert(house.id)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackupError.storeUnavailable(underlying: error)
        }
        var existingPassantIDs = Set<UUID>()
        do {
            try modelContext.enumerate(FetchDescriptor<Passant>(), batchSize: 200) { passant in
                if visited.isMultiple(of: 64) { try Task.checkCancellation() }
                visited += 1
                existingPassantIDs.insert(passant.id)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackupError.storeUnavailable(underlying: error)
        }

        // Türen vorab codieren (einmalig, Hintergrund): spart pro Haus ein
        // Platzhalter-Encode auf dem Import-Thread bei 5 000 Zeilen.
        let encoder = AppCoders.unitsEncoder()
        var unitsDataByHouseID: [UUID: Data] = [:]
        unitsDataByHouseID.reserveCapacity(backup.houses.count)
        for house in backup.houses {
            unitsDataByHouseID[house.id] = try encoder.encode(house.units)
        }

        var gebietIDMap: [UUID: UUID] = [:]
        var importedGebiete = 0
        for backupGebiet in backup.gebiete.sorted(by: { $0.day1Date < $1.day1Date }) {
            try Task.checkCancellation()
            // Nur per Identität matchen: gleiche Kalenderdaten zweier Teams
            // dürfen nie still zu einem Gebiet verschmelzen.
            if let existing = gebieteByID[backupGebiet.id] {
                gebietIDMap[backupGebiet.id] = existing.id
                if existing.boundaryData.isEmpty && !backupGebiet.boundaryData.isEmpty {
                    existing.boundaryData = backupGebiet.boundaryData
                    existing.touch()
                }
                if existing.name.isEmpty && !backupGebiet.name.isEmpty {
                    existing.rename(to: backupGebiet.name)
                }
                continue
            }
            let gebiet = Gebiet(
                name: backupGebiet.name,
                districtOrCity: backupGebiet.districtOrCity,
                date: backupGebiet.day1Date,
                isTwoDay: backupGebiet.isTwoDay
            )
            gebiet.id = backupGebiet.id
            gebiet.notes = backupGebiet.notes
            gebiet.assignDays(day1: backupGebiet.day1Date, day2: backupGebiet.day2Date)
            gebiet.boundaryData = backupGebiet.boundaryData
            gebiet.createdAt = backupGebiet.createdAt
            gebiet.updatedAt = backupGebiet.updatedAt
            modelContext.insert(gebiet)
            gebieteByID[gebiet.id] = gebiet
            gebietIDMap[backupGebiet.id] = gebiet.id
            importedGebiete += 1
        }

        var importedHouses = 0
        var skippedHouses = 0
        var batchCount = 0
        for backupHouse in backup.houses {
            try Task.checkCancellation()
            guard !existingHouseIDs.contains(backupHouse.id) else {
                skippedHouses += 1
                continue
            }
            guard let sourceGebietID = backupHouse.gebietID ?? backupHouse.dayID,
                  let targetGebietID = gebietIDMap[sourceGebietID] else {
                skippedHouses += 1
                continue
            }
            let house = House(
                address: backupHouse.address,
                latitude: backupHouse.latitude,
                longitude: backupHouse.longitude,
                gebietID: targetGebietID,
                isApartmentBuilding: backupHouse.isApartmentBuilding,
                unitCount: max(backupHouse.units.count, 1),
                unitsData: unitsDataByHouseID[backupHouse.id]
            )
            house.id = backupHouse.id
            house.note = backupHouse.note
            house.createdAt = backupHouse.createdAt
            house.updatedAt = backupHouse.updatedAt
            modelContext.insert(house)
            existingHouseIDs.insert(house.id)
            importedHouses += 1
            batchCount += 1
            if batchCount >= Self.batchSize {
                try modelContext.save()
                batchCount = 0
            }
        }
        if batchCount > 0 {
            try modelContext.save()
        }

        var importedPassanten = 0
        for backupPassant in backup.passanten {
            try Task.checkCancellation()
            guard !existingPassantIDs.contains(backupPassant.id) else {
                skippedHouses += 1
                continue
            }
            guard let sourceGebietID = backupPassant.gebietID,
                  let targetGebietID = gebietIDMap[sourceGebietID] else {
                skippedHouses += 1
                continue
            }
            let passant = Passant(
                note: backupPassant.note,
                latitude: backupPassant.latitude,
                longitude: backupPassant.longitude,
                gebietID: targetGebietID
            )
            passant.id = backupPassant.id
            passant.outcome = backupPassant.outcome
            passant.revisitAt = backupPassant.revisitAt
            passant.createdAt = backupPassant.createdAt
            passant.updatedAt = backupPassant.updatedAt
            modelContext.insert(passant)
            existingPassantIDs.insert(passant.id)
            importedPassanten += 1
        }

        try modelContext.save()
        return BackupImportResult(
            importedGebiete: importedGebiete,
            importedHouses: importedHouses,
            importedPassanten: importedPassanten,
            skippedHouses: skippedHouses
        )
    }
}

enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case unreadableFile
    case corruptContents(underlying: (any Error)?)
    case unreadableHouse(address: String)
    case storeUnavailable(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Dieses Backup wurde mit einer neueren App-Version erstellt (Format \(version)). Bitte aktualisiere die App."
        case .unreadableFile:
            "Diese Datei ist kein Nachbesuch-Backup."
        case .corruptContents:
            "Das Backup ist unvollständig oder beschädigt und konnte nicht gelesen werden."
        case .unreadableHouse(let address):
            "Die Türdaten von „\(address)“ konnten nicht gelesen werden. Es wurde kein Backup geschrieben, damit nichts verloren geht."
        case .storeUnavailable:
            "Der lokale Datenspeicher konnte nicht gelesen werden. Der Import wurde nicht ausgeführt."
        }
    }
}
