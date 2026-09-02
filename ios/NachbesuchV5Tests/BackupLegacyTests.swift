import Foundation
import SwiftData
import Testing
@testable import NachbesuchV5

/// The v1 backup reader (`days:` instead of `gebiete:`, reduced fields) runs on
/// a user's only copy of their work and had no test at all. These hold it:
/// the committed fixture decodes, a struct-built twin agrees with the file, a
/// house whose territory is missing from the file is skipped rather than
/// orphaned or crashed, and v1 → import → export-as-v2 → import is lossless
/// for everything v1 could express.
@Suite("Legacy-v1-Backup-Import")
struct BackupLegacyTests {
    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private func fixtureURL() throws -> URL {
        let found = Bundle.allBundles.compactMap {
            $0.url(forResource: "LegacyV1Fixture", withExtension: "json")
        }
        guard let url = found.first else {
            Issue.record("LegacyV1Fixture.json fehlt im Test-Bundle")
            throw BackupLegacyHarness.missingFixture
        }
        return url
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-v1-\(UUID().uuidString).json", isDirectory: false)
    }

    @Test("Die Fixture-Datei dekodiert zu Gebieten und Türen")
    func fixtureFileDecodes() async throws {
        let backup = try await BackupService.readBackup(from: fixtureURL())
        #expect(backup.formatVersion == 2)
        #expect(backup.gebiete.count == 2)
        #expect(backup.houses.count == 3)

        let first = try #require(backup.houses.first { $0.address == "Alte Straße 1" })
        let door = try #require(first.units.first)
        #expect(door.outcome == .notHome)
        #expect(door.day2Outcome == .joined)

        let dayID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        #expect(first.gebietID == dayID)
        let gebiet = try #require(backup.gebiete.first { $0.id == dayID })
        #expect(gebiet.isTwoDay == false)
        #expect(gebiet.name.hasPrefix("Gebiet vom "))
        #expect(gebiet.name.contains("2024"))
    }

    @Test("Aus Structs gebaut dekodiert identisch zur Datei")
    func structBuiltMatchesFile() async throws {
        let dayID = UUID()
        let v1 = LegacyAppBackup(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1_000_000),
            days: [LegacyBackupDay(
                id: dayID,
                date: Date(timeIntervalSince1970: 900_000),
                createdAt: Date(timeIntervalSince1970: 900_001),
                boundaryData: Data()
            )],
            houses: [LegacyBackupHouse(
                id: UUID(),
                address: "Strukturweg 1",
                note: "",
                latitude: 48.2,
                longitude: 16.3,
                isApartmentBuilding: false,
                dayID: dayID,
                units: [DoorResult(label: "Haushalt", outcome: .joined)],
                createdAt: Date(timeIntervalSince1970: 900_002),
                updatedAt: Date(timeIntervalSince1970: 900_003)
            )]
        )
        let url = temporaryURL()
        try AppCoders.backupEncoder().encode(v1).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let backup = try await BackupService.readBackup(from: url)
        #expect(backup.gebiete.count == 1)
        #expect(backup.houses.count == 1)
        #expect(backup.houses.first?.gebietID == dayID)
        #expect(backup.houses.first?.units.first?.outcome == .joined)
    }

    @Test("Haus ohne Gebiet wird übersprungen, nicht verwaist")
    @MainActor
    func missingTerritoryHouseIsSkipped() async throws {
        let container = try container()
        let backup = try await BackupService.readBackup(from: fixtureURL())
        let result = try await BackupService.importBackup(backup, into: ModelContext(container))
        #expect(result.importedGebiete == 2)
        #expect(result.importedHouses == 2)
        #expect(result.skippedHouses == 1)

        let context = ModelContext(container)
        let houses = try context.fetch(FetchDescriptor<House>())
        let gebietIDs = Set(try context.fetch(FetchDescriptor<Gebiet>()).map(\.id))
        #expect(houses.count == 2)
        #expect(houses.allSatisfy { $0.gebietID.map(gebietIDs.contains) ?? false })
    }

    @Test("v1 → Import → v2-Export → Import ist verlustfrei")
    @MainActor
    func roundTripIsLossless() async throws {
        let first = try container()
        let v1 = try await BackupService.readBackup(from: fixtureURL())
        _ = try await BackupService.importBackup(v1, into: ModelContext(first))

        let contextA = ModelContext(first)
        let gebieteA = try contextA.fetch(FetchDescriptor<Gebiet>())
        let housesA = try contextA.fetch(FetchDescriptor<House>())
        let data = try await BackupService.makeBackupData(gebiete: gebieteA, houses: housesA)
        let url = temporaryURL()
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let v2 = try await BackupService.readBackup(from: url)
        #expect(v2.gebiete.count == 2)
        #expect(v2.houses.count == 2)
        let second = try container()
        let result = try await BackupService.importBackup(v2, into: ModelContext(second))
        // The orphaned v1 house never entered the chain — it was correctly
        // skipped at the first import — so the re-import skips nothing.
        #expect(result.importedGebiete == 2)
        #expect(result.importedHouses == 2)
        #expect(result.skippedHouses == 0)

        let contextB = ModelContext(second)
        let housesB = try contextB.fetch(FetchDescriptor<House>())
        for houseA in housesA where houseA.gebietID != nil {
            let twin = try #require(housesB.first { $0.id == houseA.id })
            #expect(twin.address == houseA.address)
            #expect(twin.note == houseA.note)
            #expect(twin.latitude == houseA.latitude)
            #expect(twin.longitude == houseA.longitude)
            let doorsA = houseA.decodedUnits() ?? []
            let doorsB = twin.decodedUnits() ?? []
            #expect(doorsB.map(\.label) == doorsA.map(\.label))
            #expect(doorsB.compactMap(\.outcome) == doorsA.compactMap(\.outcome))
            #expect(doorsB.compactMap(\.day2Outcome) == doorsA.compactMap(\.day2Outcome))
        }
        let namesA = Set(gebieteA.map(\.name))
        let namesB = Set(try contextB.fetch(FetchDescriptor<Gebiet>()).map(\.name))
        #expect(namesB == namesA)
    }
}

private enum BackupLegacyHarness: Error {
    case missingFixture
}
