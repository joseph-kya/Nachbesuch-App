import Foundation
import SwiftData
import Testing
@testable import NachbesuchV5

/// The map used to rebuild its whole pin snapshot after every door tap, because the
/// only signal it had was "something in this territory changed". It now keeps a
/// watermark of the newest `updatedAt` it drew and asks for just what has been
/// written since — which is the difference between a status tap costing one row and
/// costing the territory. These hold that contract: `House.touch()` is monotonic, so
/// a changed row must always sort *after* the watermark, and an unchanged territory
/// must come back empty rather than "everything".
@Suite("Inkrementelles Kartenlesen")
struct HouseReadServiceTests {

    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func seed(_ container: ModelContainer, territory: UUID, count: Int) throws {
        let context = ModelContext(container)
        for index in 0..<count {
            context.insert(
                House(
                    address: "Teststraße \(index + 1)",
                    latitude: 48.2 + Double(index) / 10_000,
                    longitude: 16.37,
                    gebietID: territory,
                    isApartmentBuilding: false,
                    unitCount: 1
                )
            )
        }
        try context.save()
    }

    @Test("Ein volles Lesen liefert das ganze Gebiet")
    func fullReadReturnsEverything() async throws {
        let container = try container()
        let territory = UUID()
        try await seed(container, territory: territory, count: 5)

        let reader = await HouseReadService.background(container: container)
        let all = try await reader.mapSeeds(territoryID: territory, updatedAfter: nil)
        #expect(all.count == 5)
        #expect(all.allSatisfy { $0.updatedAt != nil }, "Die Wasserlinie braucht den Zeitstempel")
    }

    @Test("Ein fremdes Gebiet bleibt draußen")
    func otherTerritoriesAreExcluded() async throws {
        let container = try container()
        let mine = UUID()
        let theirs = UUID()
        try await seed(container, territory: mine, count: 3)
        try await seed(container, territory: theirs, count: 4)

        let reader = await HouseReadService.background(container: container)
        #expect(try await reader.mapSeeds(territoryID: mine, updatedAfter: nil).count == 3)
    }

    @Test("Ohne Änderung liefert das inkrementelle Lesen nichts")
    func quietTerritoryReadsNothing() async throws {
        let container = try container()
        let territory = UUID()
        try await seed(container, territory: territory, count: 4)

        let reader = await HouseReadService.background(container: container)
        let all = try await reader.mapSeeds(territoryID: territory, updatedAfter: nil)
        let watermark = try #require(all.compactMap(\.updatedAt).max())

        let since = try await reader.mapSeeds(territoryID: territory, updatedAfter: watermark)
        #expect(since.isEmpty, "Eine unveränderte Runde darf kein Haus zurückgeben")
    }

    /// The one that matters in the field: tapping a status on one door must bring
    /// back exactly that house, not the territory.
    @MainActor
    @Test("Nach einer Änderung kommt genau das geänderte Haus zurück")
    func onlyTheTouchedHouseComesBack() async throws {
        let container = try container()
        let territory = UUID()
        try await seed(container, territory: territory, count: 6)

        let reader = await HouseReadService.background(container: container)
        let all = try await reader.mapSeeds(territoryID: territory, updatedAfter: nil)
        let watermark = try #require(all.compactMap(\.updatedAt).max())

        let context = ModelContext(container)
        let houses = try context.fetch(
            FetchDescriptor<House>(predicate: #Predicate { $0.gebietID == territory })
        )
        let target = try #require(houses.first)
        let door = try #require(target.units.first)
        target.setOutcome(.notHome, for: door.id, day: 1)
        try context.save()

        let since = try await reader.mapSeeds(territoryID: territory, updatedAfter: watermark)
        #expect(since.count == 1)
        #expect(since.first?.id == target.id)
        // Monotonic `touch()` guarantees the next watermark actually advances, so the
        // same change cannot be handed back a second time.
        let next = try #require(since.compactMap(\.updatedAt).max())
        #expect(next > watermark)
        #expect(try await reader.mapSeeds(territoryID: territory, updatedAfter: next).isEmpty)
    }
}
