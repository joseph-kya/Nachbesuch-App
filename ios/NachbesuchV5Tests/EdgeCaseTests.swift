import CoreLocation
import Foundation
import SwiftData
import Testing
import UIKit
@testable import NachbesuchV5

/// Belege für Verhalten, das bisher nur per Konvention galt —
/// Batch-Abbildung der Erinnerungen, Export-Deckel, ID-Läufe, Boundary-
/// Kurzschluss, Token-Deckel und PinArt-Rückschnitt. Schnell, keine UI-Tests.

@Suite("Später — Batch-Abbildung")
struct ReminderBatchMappingTests {

    private func candidate(date: Date, address: String = "Teststraße 1") -> RevisitReminderCandidate {
        RevisitReminderCandidate(
            houseID: UUID(), doorID: UUID(), day: 1,
            address: address, doorLabel: "Haushalt",
            isApartmentBuilding: false, date: date
        )
    }

    @Test("Vergangenheit zählt als fällig, nicht als geplant")
    func pastCountsAsDue() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let plan = ReminderService.plan([
            candidate(date: now.addingTimeInterval(-60)),
            candidate(date: now.addingTimeInterval(60))
        ], now: now)

        #expect(plan.dueInApp == 1, "Vergangene Zeit wird storniert statt geplant")
        #expect(plan.scheduledCandidates.count == 1)
        #expect(plan.overflow == 0)
    }

    @Test("Der Batch deckelt auf 49, der Rest bleibt in der App sichtbar")
    func budgetCapKeepsOverflowVisible() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let candidates = (0..<100).map { index in
            candidate(
                date: now.addingTimeInterval(Double(index + 1) * 60),
                address: "Teststraße \(index)"
            )
        }
        let plan = ReminderService.plan(candidates, now: now)

        #expect(plan.dueInApp == 0)
        #expect(plan.scheduledCandidates.count == ReminderService.revisitBudget)
        #expect(plan.overflow == 100 - ReminderService.revisitBudget)
        #expect(plan.scheduledCandidates.first?.address == "Teststraße 0", "Früheste zuerst")
    }

    @Test("splitForBatch trennt Storno von Planung")
    func splitSeparatesPastFromFuture() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let split = ReminderService.splitForBatch([
            candidate(date: now.addingTimeInterval(-120)),
            candidate(date: now),
            candidate(date: now.addingTimeInterval(120))
        ], now: now)

        // `<= now` ist Storno (wie `scheduleRevisit`), `> now` ist Planung.
        #expect(split.past.count == 2)
        #expect(split.future.count == 1)
        #expect(split.past.allSatisfy { $0.date <= now })
    }
}

@Suite("Export-IDs")
struct ExportIDsTests {

    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func seed(_ container: ModelContainer, mine: UUID, theirs: UUID) throws {
        let context = ModelContext(container)
        for index in 0..<3 {
            context.insert(House(
                address: "Meine Straße \(index + 1)",
                latitude: 48.2, longitude: 16.37,
                gebietID: mine, isApartmentBuilding: false, unitCount: 1
            ))
        }
        for index in 0..<2 {
            context.insert(House(
                address: "Fremde Straße \(index + 1)",
                latitude: 48.2, longitude: 16.37,
                gebietID: theirs, isApartmentBuilding: false, unitCount: 1
            ))
        }
        for index in 0..<2 {
            context.insert(Passant(
                note: "Begegnung \(index + 1)",
                latitude: 48.2, longitude: 16.37, gebietID: mine
            ))
        }
        context.insert(Passant(
            note: "Fremde Begegnung",
            latitude: 48.2, longitude: 16.37, gebietID: theirs
        ))
        try context.save()
    }

    @Test("exportIDs liefert nur das eigene Gebiet — Häuser wie Passanten")
    func exportIDsStayWithinTerritory() async throws {
        let container = try container()
        let mine = UUID()
        let theirs = UUID()
        try await seed(container, mine: mine, theirs: theirs)

        // Belegt nebenbei den Hintergrund-Pfad: Der Reader entsteht detached und
        // liest trotzdem das volle Gebiet.
        let reader = await HouseReadService.background(container: container)
        let ids = try await reader.exportIDs(territoryID: mine)

        #expect(ids.houses.count == 3)
        #expect(ids.passanten.count == 2)
    }

    @Test("passantIDs liefert nur Begegnungen des Gebiets")
    func passantIDsStayWithinTerritory() async throws {
        let container = try container()
        let mine = UUID()
        let theirs = UUID()
        try await seed(container, mine: mine, theirs: theirs)

        let reader = await HouseReadService.background(container: container)
        #expect(try await reader.passantIDs(territoryID: mine).count == 2)
        #expect(try await reader.passantIDs(territoryID: theirs).count == 1)
    }
}

@Suite("Export-Deckel")
struct FetchBatchLimitTests {

    @Test("Normale Läufe passieren, pathologische werfen")
    func limitGuardsPathologicalStores() throws {
        try HouseReadService.checkFetchBatch(0)
        try HouseReadService.checkFetchBatch(HouseReadService.fetchBatchLimit)
        #expect(HouseReadService.fetchBatchLimit == 10_000)
        #expect(throws: HouseReadError.self) {
            try HouseReadService.checkFetchBatch(HouseReadService.fetchBatchLimit + 1)
        }
    }

    @Test("Die Fehlermeldung nennt die Grenze auf Deutsch")
    func errorNamesTheLimit() {
        let error = HouseReadError.tooManyResults(limit: 10_000)
        #expect((error.errorDescription ?? "").contains("10.000") || (error.errorDescription ?? "").contains("10000"))
    }
}

@Suite("Gebietsgrenze")
struct GebietBoundaryShortCircuitTests {

    private func triangle() -> [CLLocationCoordinate2D] {
        [
            .init(latitude: 48.20, longitude: 16.30),
            .init(latitude: 48.24, longitude: 16.36),
            .init(latitude: 48.22, longitude: 16.33)
        ]
    }

    @Test("Ohne Grenze kein Decode — der Normalfall ist billig")
    func emptyBlobHasNoBoundary() {
        let gebiet = Gebiet(name: "Leer", districtOrCity: "Wien")
        #expect(gebiet.boundaryData.isEmpty)
        #expect(!gebiet.hasBoundary)
    }

    @Test("Erst drei Punkte sind eine Grenze")
    func threePointsMakeABoundary() {
        var two = triangle()
        two.removeLast()
        #expect(!Gebiet(name: "A", districtOrCity: "Wien", boundaryCoordinates: two).hasBoundary)
        #expect(Gebiet(name: "B", districtOrCity: "Wien", boundaryCoordinates: triangle()).hasBoundary)
    }
}

@Suite("Token-Deckel")
struct BuilderTokenCapTests {

    private func row(searchText: String) -> HouseRowModel {
        HouseRowModel(
            id: UUID(), address: "Teststraße 1", note: "", street: "Teststraße",
            houseNumber: "1", shortAddress: "Teststraße 1",
            markerOutcome: nil, unitCount: 1, completedCount: 0,
            followUpCount: 0, joinedCount: 0, laterCount: 0, openCount: 1,
            createdAt: .now, searchText: searchText, latitude: 0, longitude: 0,
            recordedAt: nil, nextRevisitAt: nil
        )
    }

    @Test("Der elfte Token begrenzt nicht die Treffer")
    func eleventhTokenIsIgnored() {
        let query = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo"
        #expect(SearchText.tokenize(query).count == 11, "Belegt, dass der Deckel greift")
        let partial = row(searchText: "alpha bravo charlie delta echo foxtrot golf hotel india juliet")
        #expect(!partial.searchText.contains("kilo"))
        let full = row(searchText: "\(partial.searchText) kilo")

        let result = HouseListBuilder.filter([partial, full], filter: .all, query: query)
        #expect(result.count == 2, "Builder-seitiges prefix(10) als Abwehr-Tiefe")
    }
}

@MainActor
@Suite("PinArtCache-Rückschnitt")
struct PinCacheTrimTests {

    private func key(_ text: String) -> PinArtCache.Key {
        PinArtCache.Key(outcome: .notHome, text: text, isSelected: false, isDark: false, scale: .full)
    }

    @Test("Volle Ablage verdrängt den ältesten Eintrag")
    func fullCacheEvictsOldest() {
        let cache = PinArtCache(limit: 3)
        let first = cache.pinImage(for: key("1"))
        _ = cache.pinImage(for: key("2"))
        _ = cache.pinImage(for: key("3"))
        _ = cache.pinImage(for: key("4"))

        #expect(cache.pinImage(for: key("1")) !== first, "Ältester Eintrag neu gerendert")
        let kept = cache.pinImage(for: key("4"))
        #expect(cache.pinImage(for: key("4")) === kept, "Jüngster Eintrag überlebt")
    }

    @Test("clear(keeping:) behält die jüngsten Einträge")
    func clearKeepsYoungest() {
        let cache = PinArtCache()
        let refs = (1...5).map { cache.pinImage(for: key("t\($0)")) }
        cache.clear(keeping: 2)

        #expect(cache.pinImage(for: key("t4")) === refs[3])
        #expect(cache.pinImage(for: key("t5")) === refs[4])
        #expect(cache.pinImage(for: key("t1")) !== refs[0], "Ältester Eintrag verworfen")
    }

    @Test("clear() ohne Angabe leert alles")
    func clearDropsEverything() {
        let cache = PinArtCache()
        let before = cache.pinImage(for: key("x"))
        cache.clear()
        #expect(cache.pinImage(for: key("x")) !== before)
    }
}
