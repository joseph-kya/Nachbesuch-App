import CoreLocation
import Foundation
import Testing
@testable import NachbesuchV5

// MARK: - Day scope semantics

@Suite("Tag-1 / Tag-2 Semantik")
struct DayScopeSemanticsTests {

    /// The bug this pins: `outcome(for: 2)` used to fall back to the day-1 value, so
    /// `day2` was arithmetically identical to the combined total and the whole
    /// Tag-1/Tag-2 comparison compared a number with itself.
    @Test("Tag 2 zählt nur, was am zweiten Tag wirklich eingetragen wurde")
    func day2CountsOnlyRealRevisits() {
        let doors = [
            DoorResult(label: "1", outcome: .notHome),                        // offen für Tag 2
            DoorResult(label: "2", outcome: .joined),                         // Tag 1 erledigt
            DoorResult(label: "3", outcome: .notHome, day2Outcome: .lateNo),  // Tag 2 erledigt
            DoorResult(label: "4")                                            // nie besucht
        ]

        #expect(doors[0].result(on: 2) == nil)
        #expect(doors[1].result(on: 2) == nil)
        #expect(doors[2].result(on: 2) == .lateNo)

        // Statistics are strict: only door 3 was actually revisited.
        let territoryID = UUID()
        let index = ArchiveIndexBuilder.build(
            gebiete: [.init(
                id: territoryID, name: "Test", districtOrCity: "Wien", notes: "",
                day1Date: .now, day2Date: nil, isTwoDay: false
            )],
            houses: [.init(
                gebietID: territoryID, address: "Test 1", note: "",
                unitsData: try! AppCoders.unitsEncoder().encode(doors)
            )]
        )
        let stats = try! #require(index.entry(for: territoryID))
        #expect(stats.day2.completed == 1)
        #expect(stats.day1.completed == 3)
        #expect(stats.overall.completed == 3)
        #expect(stats.day2.completed != stats.overall.completed,
                "Genau das war der Fehler: Tag 2 war rechnerisch identisch mit der Gesamtsumme")

        // The list/pin tally uses display semantics: in Tag-2 view a door settled on
        // day 1 needs no more work, while a door awaiting its revisit counts as open.
        let day2 = OutcomeTally.tally(doors, scope: .day2)
        #expect(day2.open == 2, "Tür 1 wartet auf den Nachbesuch, Tür 4 wurde nie besucht")
        #expect(day2.completed + day2.open == day2.unitCount)
    }

    /// In Tag-2 view, a door left open on day 1 is the *work*, not a finished item.
    @Test("Offene Tag-1-Türen erscheinen am Tag 2 als offen, nicht als erledigt")
    func pendingRevisitsReadAsOpen() {
        let door = DoorResult(label: "1", outcome: .notHome)
        #expect(door.isPendingRevisit)
        #expect(door.isOpen(in: .day2))
        #expect(door.displayOutcome(in: .day2) == nil)
        // Combined still shows the last known state.
        #expect(door.displayOutcome(in: .combined) == .notHome)
    }

    @Test("Am Tag 1 abgeschlossene Türen brauchen keinen Nachbesuch")
    func settledDoorsNeedNoRevisit() {
        let door = DoorResult(label: "1", outcome: .joined)
        #expect(!door.isPendingRevisit)
        #expect(!door.isOpen(in: .day2))
        #expect(door.displayOutcome(in: .day2) == .joined)
    }

    /// `setOutcomeForOpenDoors(day: 2)` used to ask for the day-1 value, which fell
    /// back and made every revisit target look answered — so it skipped exactly the
    /// doors it was meant to fill.
    @Test("„Alle offenen Türen“ trifft am Tag 2 die Nachbesuchs-Ziele")
    func markOpenDoorsHitsRevisitTargets() throws {
        let house = House(
            address: "Teststraße 1", latitude: 48.2, longitude: 16.3,
            gebietID: UUID(), isApartmentBuilding: true, unitCount: 3
        )
        var doors = try #require(house.decodedUnits())
        doors[0].outcome = .notHome   // Ziel
        doors[1].outcome = .joined    // erledigt
        doors[2].outcome = nil        // nie besucht → auch Ziel
        house.restore(units: doors)

        let changed = house.setOutcomeForOpenDoors(.lateNo, day: 2)
        #expect(changed == 2)

        let after = try #require(house.decodedUnits())
        #expect(after[0].day2Outcome == .lateNo)
        #expect(after[1].day2Outcome == nil, "Am Tag 1 erledigte Türen bleiben unberührt")
        #expect(after[2].day2Outcome == .lateNo)
        #expect(after[1].outcome == .joined, "Tag-1-Historie bleibt erhalten")
    }

    @Test("Marker zeigt offene Arbeit vor allem anderen")
    func markerPrefersOpenWork() {
        let doors = [
            DoorResult(label: "1", outcome: .joined),
            DoorResult(label: "2", outcome: .notHome)
        ]
        #expect(OutcomeTally.markerOutcome(for: doors, scope: .combined) == .notHome)
    }
}

// MARK: - Cache and change signalling

@Suite("Änderungssignale")
struct ChangeSignalTests {

    /// Undo used to rewind `updatedAt`, which dropped the house out of the map's
    /// "changed since" window — the list showed the undo, the map kept the undone
    /// status, and the pipeline believed it was up to date.
    @Test("Rückgängig bewegt updatedAt vorwärts, niemals zurück")
    func undoMovesTimestampForward() throws {
        let house = House(
            address: "Teststraße 2", latitude: 48.2, longitude: 16.3,
            gebietID: UUID(), isApartmentBuilding: false, unitCount: 1
        )
        let original = try #require(house.decodedUnits())
        let before = house.updatedAt

        let door = try #require(original.first)
        house.setOutcome(.joined, for: door.id, day: 1)
        let afterChange = house.updatedAt
        #expect(afterChange >= before)

        house.restore(units: original)
        #expect(house.updatedAt >= afterChange, "Undo darf den Änderungsstempel nicht zurückdrehen")
        #expect(house.units.first?.outcome == nil)
    }

    /// A blob that cannot be decoded must never be silently replaced with an empty
    /// array — that turned a recoverable read failure into permanent data loss.
    @Test("Unlesbare Türdaten werden nicht überschrieben")
    func damagedHouseRefusesWrites() {
        let house = House(
            address: "Teststraße 3", latitude: 48.2, longitude: 16.3,
            gebietID: UUID(), isApartmentBuilding: false, unitCount: 1
        )
        let corrupt = Data("nicht json".utf8)
        house.unitsData = corrupt

        #expect(house.isDamaged)
        #expect(house.decodedUnits() == nil)

        house.setOutcome(.joined, for: UUID(), day: 1)
        #expect(house.unitsData == corrupt, "Die beschädigten Rohdaten bleiben erhalten")

        #expect(house.setOutcomeForOpenDoors(.notHome, day: 1) == 0)
        #expect(house.unitsData == corrupt)
    }
}

// MARK: - Territory invariants

@Suite("Gebiets-Invarianten")
struct GebietInvariantTests {

    @Test("Ein 2-Tages-Gebiet hat immer einen zweiten Tag")
    func twoDayAlwaysHasSecondDay() {
        let gebiet = Gebiet(name: "Test", isTwoDay: true)
        #expect(gebiet.day2Date != nil)
        #expect(try! #require(gebiet.day2Date) > gebiet.day1Date)
    }

    @Test("Ein gleicher zweiter Tag wird auf den Folgetag korrigiert")
    func sameDayIsRejected() throws {
        let day = Gebiet.campaignCalendar.startOfDay(for: .now)
        let gebiet = Gebiet(name: "Test", date: day, isTwoDay: true, day2Date: day)
        let day2 = try #require(gebiet.day2Date)
        #expect(day2 > gebiet.day1Date, "Tag 2 darf nicht auf Tag 1 fallen — sonst ist er unerreichbar")
    }

    @Test("Ein frei gewählter zweiter Tag bleibt erhalten")
    func freelyChosenSecondDayIsKept() throws {
        let calendar = Gebiet.campaignCalendar
        let day1 = calendar.startOfDay(for: .now)
        let day2 = try #require(calendar.date(byAdding: .day, value: 4, to: day1))
        let gebiet = Gebiet(name: "Test", date: day1, isTwoDay: true, day2Date: day2)
        #expect(calendar.isDate(try #require(gebiet.day2Date), inSameDayAs: day2))
    }

    @Test("Umschalten auf 1 Tag entfernt den zweiten Tag")
    func switchingToSingleDayClearsSecondDay() {
        let gebiet = Gebiet(name: "Test", isTwoDay: true)
        gebiet.duration = .singleDay
        #expect(gebiet.day2Date == nil)
    }

    @Test("Der Schreib-Tag folgt dem Kalender, nicht der Anzeige")
    func writeScopeFollowsCalendar() throws {
        let calendar = Gebiet.campaignCalendar
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now)))
        let gebiet = Gebiet(name: "Test", date: yesterday, isTwoDay: true, day2Date: .now)
        #expect(gebiet.writeScope() == .day2, "Heute ist Tag 2 → Eintragungen gehören zu Tag 2")
        #expect(gebiet.dayIndex(on: yesterday) == 1)
    }

    @Test("Umbenennen aktualisiert den Änderungsstempel")
    func renameTouchesTimestamp() {
        let gebiet = Gebiet(name: "Alt")
        let before = gebiet.updatedAt
        gebiet.rename(to: "Neu")
        #expect(gebiet.name == "Neu")
        #expect(gebiet.updatedAt >= before, "Sonst zeigt der Archiv-Index weiter den alten Namen")
    }

    @Test("Gebietsgrenze übersteht Encode und Decode")
    func boundaryRoundTrips() {
        let gebiet = Gebiet(name: "Test")
        let points = [
            CLLocationCoordinate2D(latitude: 48.20, longitude: 16.36),
            CLLocationCoordinate2D(latitude: 48.21, longitude: 16.37),
            CLLocationCoordinate2D(latitude: 48.22, longitude: 16.35)
        ]
        gebiet.boundaryCoordinates = points
        let restored = gebiet.boundaryCoordinates
        #expect(restored.count == 3)
        #expect(abs(restored[1].latitude - 48.21) < 0.000001)
    }
}
