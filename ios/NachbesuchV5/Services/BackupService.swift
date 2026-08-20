import Foundation
import SwiftData

nonisolated struct AppBackup: Codable, Sendable {
    let formatVersion: Int
    let exportedAt: Date
    let gebiete: [BackupGebiet]
    let houses: [BackupHouse]
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

nonisolated struct BackupImportResult: Sendable {
    let importedGebiete: Int
    let importedHouses: Int
    let skippedHouses: Int
}

// Legacy v1 format structures for backward compatibility
private nonisolated struct LegacyAppBackup: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let days: [LegacyBackupDay]
    let houses: [LegacyBackupHouse]
}

private nonisolated struct LegacyBackupDay: Codable {
    let id: UUID
    let date: Date
    let createdAt: Date
    let boundaryData: Data
}

private nonisolated struct LegacyBackupHouse: Codable {
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
    private struct GebietSnapshot: Sendable {
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

    private struct HouseSnapshot: Sendable {
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

    static func makeBackup(gebiete: [Gebiet], houses: [House]) async throws -> URL {
        let trace = PerformanceTrace.begin("Create backup")
        defer { PerformanceTrace.end("Create backup", id: trace) }

        let gebietSnapshots = gebiete.map(GebietSnapshot.init)
        let houseSnapshots = houses.map(HouseSnapshot.init)

        return try await Task.detached(priority: .userInitiated) { () -> URL in
            let decoder = AppCoders.unitsDecoder()
            let backup = AppBackup(
                formatVersion: 2,
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
                }
            )

            let data = try AppCoders.backupEncoder().encode(backup)
            let date = Date.now.formatted(.iso8601.year().month().day())
            // Own directory per backup: files used to collide at day granularity, so
            // a second backup overwrote one the share sheet might still be reading.
            let url = try ExportScratch.makeURL(fileName: "Nachbesuch-Backup-\(date).json")
            try data.write(to: url, options: .atomic)
            return url
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
        case 2:
            do {
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
            return AppBackup(formatVersion: 2, exportedAt: v1Backup.exportedAt, gebiete: gebiete, houses: houses)
        }

        throw BackupError.corruptContents(underlying: nil)
    }

    static func importBackup(
        _ backup: AppBackup,
        into modelContext: ModelContext
    ) async throws -> BackupImportResult {
        // Read the current state HERE rather than accepting arrays captured in a view
        // body, which could already be stale by the time the loop runs.
        let existingGebiete = (try? modelContext.fetch(FetchDescriptor<Gebiet>())) ?? []
        let existingHouses = (try? modelContext.fetch(FetchDescriptor<House>())) ?? []
        do {
            return try await performImport(backup, into: modelContext,
                                           existingGebiete: existingGebiete,
                                           existingHouses: existingHouses)
        } catch {
            // Without this, a failed import stays live in the context and the next
            // unrelated save anywhere in the app silently commits half of it.
            modelContext.rollback()
            throw error
        }
    }

    private static func performImport(
        _ backup: AppBackup,
        into modelContext: ModelContext,
        existingGebiete: [Gebiet],
        existingHouses: [House]
    ) async throws -> BackupImportResult {
        let trace = PerformanceTrace.begin("Import backup")
        defer { PerformanceTrace.end("Import backup", id: trace) }

        // Pre-encode all units off the main thread; the inserts themselves stay on the
        // main-actor context where SwiftData requires them.
        let unitsDataByHouseID = await Task.detached(priority: .userInitiated) { () -> [UUID: Data] in
            let encoder = AppCoders.unitsEncoder()
            var encoded: [UUID: Data] = [:]
            encoded.reserveCapacity(backup.houses.count)
            for house in backup.houses {
                encoded[house.id] = (try? encoder.encode(house.units)) ?? Data()
            }
            return encoded
        }.value

        var gebieteByID: [UUID: Gebiet] = [:]
        for gebiet in existingGebiete {
            gebieteByID[gebiet.id] = gebieteByID[gebiet.id] ?? gebiet
        }

        var gebietIDMap: [UUID: UUID] = [:]
        var importedGebiete = 0

        for backupGebiet in backup.gebiete.sorted(by: { $0.day1Date < $1.day1Date }) {
            // Matched by identity ONLY. The old code also merged any existing
            // territory that happened to share a calendar date, so two teams
            // canvassing two districts on the same day were silently combined into
            // one — while the counter reported "0 Gebiete importiert".
            if let existing = gebieteByID[backupGebiet.id] {
                gebietIDMap[backupGebiet.id] = existing.id
                if existing.boundaryData.isEmpty && !backupGebiet.boundaryData.isEmpty {
                    existing.boundaryData = backupGebiet.boundaryData
                }
                if existing.name.isEmpty && !backupGebiet.name.isEmpty {
                    existing.name = backupGebiet.name
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
            // Through `assignDays`, so a two-day territory can never end up with a
            // nil second day — assigning the field directly wrote past the invariant.
            gebiet.assignDays(day1: backupGebiet.day1Date, day2: backupGebiet.day2Date)
            gebiet.boundaryData = backupGebiet.boundaryData
            gebiet.createdAt = backupGebiet.createdAt
            gebiet.updatedAt = backupGebiet.updatedAt

            modelContext.insert(gebiet)
            gebieteByID[gebiet.id] = gebiet
            gebietIDMap[backupGebiet.id] = gebiet.id
            importedGebiete += 1
        }

        var existingHouseIDs = Set(existingHouses.map(\.id))
        var importedHouses = 0
        var skippedHouses = 0

        for backupHouse in backup.houses {
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
                // Pre-encoded: passing it to the initializer skips encoding a
                // placeholder array that would be overwritten on the next line —
                // one wasted JSON encode per house, on the main actor, at import scale.
                unitsData: unitsDataByHouseID[backupHouse.id]
            )
            house.id = backupHouse.id
            house.note = backupHouse.note
            house.createdAt = backupHouse.createdAt
            house.updatedAt = backupHouse.updatedAt
            modelContext.insert(house)
            existingHouseIDs.insert(house.id)
            importedHouses += 1
        }

        try modelContext.save()
        return BackupImportResult(
            importedGebiete: importedGebiete,
            importedHouses: importedHouses,
            skippedHouses: skippedHouses
        )
    }
}

enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case unreadableFile
    case corruptContents(underlying: (any Error)?)
    case unreadableHouse(address: String)

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
        }
    }
}
