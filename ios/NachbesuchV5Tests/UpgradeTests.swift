import Foundation
import Testing
@testable import NachbesuchV5

@Suite("Upgrade reliability contract")
struct UpgradeTests {
    @Test func damagedDataHasOneMeaningEverywhere() async {
        let damaged = Data("not-json".utf8)
        #expect(HouseDataState.decode(damaged) == .damaged)

        let raw = RawMapHouse(
            id: UUID(), address: "Teststraße 1", latitude: 48.2, longitude: 16.3,
            unitsData: damaged
        )
        let map = MapPinSnapshotBuilder.build(from: [raw], scope: .combined)
        #expect(map.stats.damagedHouseCount == 1)
        #expect(map.pinsByID[raw.id]?.markerText == "!")

        let territoryID = UUID()
        let index = ArchiveIndexBuilder.build(
            gebiete: [.init(
                id: territoryID, name: "Test", districtOrCity: "Wien", notes: "",
                day1Date: .now, day2Date: nil, isTwoDay: false
            )],
            houses: [.init(
                gebietID: territoryID, address: "Teststraße 1", note: "", unitsData: damaged
            )]
        )
        #expect(index.entry(for: territoryID)?.damagedHouseCount == 1)
    }

    @Test func archiveDay2UsesOnlyRevisitTargets() throws {
        let target = DoorResult(label: "Tür 1", outcome: .notHome)
        let settled = DoorResult(label: "Tür 2", outcome: .joined)
        let data = try AppCoders.unitsEncoder().encode([target, settled])
        let territoryID = UUID()
        let index = ArchiveIndexBuilder.build(
            gebiete: [.init(
                id: territoryID, name: "Test", districtOrCity: "Wien", notes: "",
                day1Date: .now, day2Date: .now.addingTimeInterval(86_400), isTwoDay: true
            )],
            houses: [.init(gebietID: territoryID, address: "Test 1", note: "", unitsData: data)]
        )
        #expect(index.entry(for: territoryID)?.revisitTargets == 1)
        #expect(index.entry(for: territoryID)?.day2.unitCount == 1)
    }

    @Test func reminderOverflowStaysVisibleInApp() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let candidates = (0..<100).map { index in
            RevisitReminderCandidate(
                houseID: UUID(), doorID: UUID(), day: 1,
                address: "Teststraße \(index)", doorLabel: "Haushalt",
                isApartmentBuilding: false,
                date: now.addingTimeInterval(Double(index + 1) * 60)
            )
        }
        let plan = ReminderService.plan(candidates, now: now)
        #expect(plan.scheduledCandidates.count == ReminderService.revisitBudget)
        #expect(plan.overflow == 100 - ReminderService.revisitBudget)
        #expect(plan.scheduledCandidates.first?.address == "Teststraße 0")
    }
}
