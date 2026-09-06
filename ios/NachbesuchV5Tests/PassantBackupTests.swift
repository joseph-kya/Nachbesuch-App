import Foundation
import SwiftData
import Testing
@testable import NachbesuchV5

/// Street encounters ride the backup (format 3): round-trip lossless, orphaned
/// encounters skipped like orphaned houses, and v2 files without the new key
/// still restore.
@Suite("Passant-Backup")
struct PassantBackupTests {
    @Test("Archiv-Sicherung enthält alle Datentypen und lässt sich wiederherstellen")
    @MainActor
    func archiveBackupIncludesEntireStore() async throws {
        let source = try container()
        let territoryID = try seed(source)
        let context = ModelContext(source)
        let house = House(address: "Teststraße 1", latitude: 48.2, longitude: 16.3,
                          gebietID: territoryID, isApartmentBuilding: false, unitCount: 1)
        context.insert(house)
        try context.save()

        // Exercise the entry point used by ArchiveScreen, not a hand-picked array.
        let url = try await BackupService.makeBackup(in: context)
        defer { try? FileManager.default.removeItem(at: url) }
        let backup = try await BackupService.readBackup(from: url)
        #expect(backup.gebiete.count == 1)
        #expect(backup.houses.count == 1)
        #expect(backup.passanten.count == 1)

        let restored = try container()
        let result = try await BackupService.importBackup(backup, into: ModelContext(restored))
        #expect(result.importedGebiete == 1)
        #expect(result.importedHouses == 1)
        #expect(result.importedPassanten == 1)
        #expect(result.skippedHouses == 0)
    }

    @Test("Abgleich erhält Passanten-Termine und entfernt erledigte Begegnungen")
    @MainActor
    func reconciliationIncludesBookedEncounters() async throws {
        let store = try container()
        let territoryID = try seed(store)
        let context = ModelContext(store)
        let booked = Passant(note: "Termin", latitude: 48.2, longitude: 16.3, gebietID: territoryID)
        booked.outcome = .later
        booked.revisitAt = Date.now.addingTimeInterval(3600)
        context.insert(booked)
        let withoutTime = Passant(note: "Ohne Termin", latitude: 48.2, longitude: 16.3, gebietID: territoryID)
        withoutTime.outcome = .later
        context.insert(withoutTime)
        let house = House(address: "Teststraße 1", latitude: 48.2, longitude: 16.3,
                          gebietID: territoryID, isApartmentBuilding: false, unitCount: 1)
        var door = try #require(house.units.first)
        door.outcome = .later
        door.revisitAt = booked.revisitAt
        house.unitsData = try AppCoders.unitsEncoder().encode([door])
        context.insert(house)
        try context.save()

        let candidates = try await HouseReadService(modelContainer: store).revisitCandidates()
        #expect(candidates.count == 2)
        let encounter = try #require(candidates.first { $0.houseID == booked.id })
        #expect(encounter.doorID == booked.id)
        #expect(encounter.day == 1)
        #expect(encounter.date == booked.revisitAt)
        #expect(encounter.address == booked.note)
        #expect(ReminderService.plan(candidates, now: .now).scheduledCandidates.count == 2)

        // A fresh reconciliation must read the persisted completion, not reschedule it.
        booked.outcome = .joined
        try context.save()
        let afterCompletion = try await HouseReadService(modelContainer: store).revisitCandidates()
        #expect(afterCompletion.count == 1)
        #expect(afterCompletion.first?.houseID == house.id)
    }

    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func seed(_ container: ModelContainer) throws -> UUID {
        let context = ModelContext(container)
        let territoryID = UUID()
        let gebiet = Gebiet(name: "Test", districtOrCity: "Wien", date: .now)
        gebiet.id = territoryID
        context.insert(gebiet)
        let passant = Passant(note: "Frau mit Hund, interessiert", latitude: 48.2, longitude: 16.3, gebietID: territoryID)
        passant.outcome = .joined
        context.insert(passant)
        try context.save()
        return territoryID
    }

    @Test("Roundtrip ist verlustfrei")
    @MainActor
    func roundTripIsLossless() async throws {
        let first = try container()
        let territoryID = try seed(first)
        let contextA = ModelContext(first)
        let data = try await BackupService.makeBackupData(
            gebiete: try contextA.fetch(FetchDescriptor<Gebiet>()),
            houses: [],
            passanten: try contextA.fetch(FetchDescriptor<Passant>())
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("passant-\(UUID().uuidString).json", isDirectory: false)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let backup = try await BackupService.readBackup(from: url)
        #expect(backup.formatVersion == 3)
        #expect(backup.passanten.count == 1)
        #expect(backup.passanten.first?.note == "Frau mit Hund, interessiert")
        #expect(backup.passanten.first?.outcome == .joined)

        let second = try container()
        let result = try await BackupService.importBackup(backup, into: ModelContext(second))
        #expect(result.importedGebiete == 1)
        #expect(result.importedPassanten == 1)
        let contextB = ModelContext(second)
        let restored = try #require(try contextB.fetch(FetchDescriptor<Passant>()).first)
        #expect(restored.note == "Frau mit Hund, interessiert")
        #expect(restored.outcome == .joined)
        #expect(restored.gebietID == territoryID)
    }

    @Test("Verwaister Passant wird übersprungen")
    @MainActor
    func orphanIsSkipped() async throws {
        let backup = AppBackup(
            formatVersion: 3,
            exportedAt: .now,
            gebiete: [],
            houses: [],
            passanten: [BackupPassant(
                id: UUID(), note: "Niemandsland", latitude: 48.2, longitude: 16.3,
                outcome: nil, revisitAt: nil, gebietID: UUID(),
                createdAt: .now, updatedAt: .now
            )]
        )
        let result = try await BackupService.importBackup(backup, into: ModelContext(try container()))
        #expect(result.importedPassanten == 0)
        #expect(result.skippedHouses == 1)
    }

    @Test("v2 ohne Passanten-Schlüssel liest sich")
    func v2WithoutPassantenKeyDecodes() async throws {
        let json = """
        {"formatVersion":2,"exportedAt":"2024-05-03T10:00:00Z","gebiete":[],"houses":[]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-\(UUID().uuidString).json", isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let backup = try await BackupService.readBackup(from: url)
        #expect(backup.formatVersion == 2)
        #expect(backup.passanten.isEmpty)
    }
}
