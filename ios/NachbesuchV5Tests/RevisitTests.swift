import Foundation
import Testing
@testable import NachbesuchV5

// MARK: - Storage compatibility

@Suite("Später — Speicherformat")
struct RevisitStorageTests {

    /// The reason `revisitAt` was added as a new optional key rather than by
    /// reshaping `DoorResult`: a blob written by a build that predates this feature
    /// must still decode, or the house shows up as damaged and locks itself.
    @Test("Alte Türdaten ohne die neuen Felder lassen sich weiterhin lesen")
    func legacyBlobStillDecodes() throws {
        let legacy = """
        [{"id":"1E5F0F3E-2C4B-4C3A-9E5A-7A0A7F2B1C11","label":"Haushalt",\
        "outcome":"notHome","updatedAt":760000000.0}]
        """.data(using: .utf8)!

        let doors = try AppCoders.unitsDecoder().decode([DoorResult].self, from: legacy)
        #expect(doors.count == 1)
        #expect(doors[0].outcome == .notHome)
        #expect(doors[0].revisitAt == nil)
        #expect(doors[0].day2RevisitAt == nil)
    }

    @Test("Eine gebuchte Zeit übersteht den Schreib-Lese-Zyklus")
    func revisitTimeRoundTrips() throws {
        let booked = Date(timeIntervalSince1970: 1_770_000_000)
        let doors = [DoorResult(label: "Tür 1", outcome: .later, updatedAt: .now, revisitAt: booked)]

        let data = try AppCoders.unitsEncoder().encode(doors)
        let decoded = try AppCoders.unitsDecoder().decode([DoorResult].self, from: data)

        #expect(decoded[0].outcome == .later)
        #expect(abs(try #require(decoded[0].revisitAt).timeIntervalSince(booked)) < 0.001)
    }

    /// `.later` is a new raw value in a frozen storage format. This pins the string
    /// so a rename can never happen by accident.
    @Test("Der gespeicherte Wert heißt „later“")
    func rawValueIsStable() {
        #expect(VisitOutcome.later.rawValue == "later")
    }
}

// MARK: - Semantics

@Suite("Später — Bedeutung")
struct RevisitSemanticsTests {

    @Test("Eine Tür mit Uhrzeit bleibt offene Arbeit")
    func laterCountsAsOpenWork() {
        let door = DoorResult(label: "1", outcome: .later, updatedAt: .now, revisitAt: .now.addingTimeInterval(3600))

        #expect(VisitOutcome.later.isOpenWork)
        #expect(door.isOpen(in: .day1))
        #expect(door.isOpen(in: .combined))
        // Same rule as "niemand da": the second day exists for exactly these doors.
        #expect(door.isPendingRevisit)
        #expect(door.displayOutcome(in: .day2) == nil)
    }

    @Test("Später schlägt „Niemand da“ auf dem Pin")
    func markerPrefersBookedTime() {
        let doors = [
            DoorResult(label: "1", outcome: .notHome),
            DoorResult(label: "2", outcome: .later, revisitAt: .now.addingTimeInterval(1800)),
            DoorResult(label: "3", outcome: .joined)
        ]
        // The booked time is the more specific instruction, and the one with a
        // deadline — so it is what the pin shows.
        #expect(OutcomeTally.markerOutcome(for: doors, scope: .combined) == .later)
    }

    @Test("Später wird eigenständig gezählt")
    func tallyKeepsLaterSeparate() {
        let doors = [
            DoorResult(label: "1", outcome: .later, revisitAt: .now.addingTimeInterval(600)),
            DoorResult(label: "2", outcome: .notHome),
            DoorResult(label: "3", outcome: .joined)
        ]
        let tally = OutcomeTally.tally(doors, scope: .combined)

        #expect(tally.later == 1)
        #expect(tally.notHome == 1, "Später darf nicht in „Niemand da“ mitgezählt werden")
        #expect(tally.completed == 3)
        #expect(tally.open == 2, "Später und Niemand da sind beide noch zu erledigen")
    }

    @Test("Eine andere Antwort löscht die gebuchte Zeit")
    func answeringClearsTheBookedTime() {
        let house = House(
            address: "Teststraße 1", latitude: 48.2, longitude: 16.3,
            gebietID: UUID(), isApartmentBuilding: false, unitCount: 1
        )
        let doorID = try! #require(house.units.first).id

        house.setOutcome(.later, for: doorID, day: 1, revisitAt: .now.addingTimeInterval(3600))
        #expect(house.units[0].revisitAt != nil)

        // Otherwise the door reads as settled while still carrying a return time —
        // and a reminder would fire for a household that already said yes.
        house.setOutcome(.joined, for: doorID, day: 1)
        #expect(house.units[0].outcome == .joined)
        #expect(house.units[0].revisitAt == nil)
    }

    @Test("Die Zeit landet auf dem Tag, auf den geschrieben wird")
    func timeIsWrittenToTheCorrectDay() {
        let house = House(
            address: "Teststraße 2", latitude: 48.2, longitude: 16.3,
            gebietID: UUID(), isApartmentBuilding: false, unitCount: 1
        )
        let doorID = try! #require(house.units.first).id
        let booked = Date.now.addingTimeInterval(7200)

        house.setOutcome(.later, for: doorID, day: 2, revisitAt: booked)
        #expect(house.units[0].revisitAt == nil)
        #expect(house.units[0].day2RevisitAt != nil)
        #expect(house.units[0].revisitTime(on: 2) != nil)
    }

    @Test("Der Sammel-Eintrag bucht dieselbe Zeit für alle offenen Türen")
    func bulkBookingCoversOpenDoorsOnly() {
        let house = House(
            address: "Teststraße 3", latitude: 48.2, longitude: 16.3,
            gebietID: UUID(), isApartmentBuilding: true, unitCount: 3
        )
        let doorID = try! #require(house.units.first).id
        house.setOutcome(.joined, for: doorID, day: 1)

        let booked = Date.now.addingTimeInterval(1800)
        let changed = house.setOutcomeForOpenDoors(.later, day: 1, revisitAt: booked)

        #expect(changed == 2)
        #expect(house.units[0].outcome == .joined, "Eine erledigte Tür wird nicht überschrieben")
        #expect(house.units[0].revisitAt == nil)
        #expect(house.units[1].revisitAt != nil)
        #expect(house.units[2].revisitAt != nil)
    }
}

// MARK: - Suggested times

@Suite("Später — Zeitvorschläge")
struct RevisitPlannerTests {

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return value
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: hour, minute: minute))!
    }

    @Test("Am frühen Nachmittag stehen relative und feste Zeiten zur Wahl")
    func middayOffersBoth() {
        let suggestions = RevisitPlanner.suggestions(now: date(13, 12), calendar: calendar)

        #expect(suggestions.count == 5)
        #expect(suggestions.allSatisfy { $0.date > self.date(13, 12) })
        // Sorted, so the row reads as a timeline rather than two shuffled groups.
        #expect(suggestions.map(\.date) == suggestions.map(\.date).sorted())
        #expect(suggestions.contains { $0.kind == .clock(hour: 17, minute: 0) })
        #expect(suggestions.contains { $0.kind == .clock(hour: 18, minute: 0) })
    }

    @Test("Vergangene Uhrzeiten werden nicht angeboten")
    func passedSlotsAreDropped() {
        let suggestions = RevisitPlanner.suggestions(now: date(18, 45), calendar: calendar)

        // 17:00 and 18:00 are gone; only 19:00 is left, so this must not silently
        // roll a slot into tomorrow.
        #expect(!suggestions.contains { $0.kind == .clock(hour: 17, minute: 0) })
        #expect(!suggestions.contains { $0.kind == .clock(hour: 18, minute: 0) })
        #expect(suggestions.contains { $0.kind == .clock(hour: 19, minute: 0) })
    }

    @Test("Spät am Abend bleiben nur die relativen Vorschläge")
    func lateEveningKeepsRelativeOnly() {
        let suggestions = RevisitPlanner.suggestions(now: date(21, 40), calendar: calendar)

        #expect(suggestions.count == RevisitPlanner.relativeOffsets.count)
        #expect(suggestions.allSatisfy { if case .relative = $0.kind { true } else { false } })
    }

    @Test("Ein fester Vorschlag verschwindet, wenn ein relativer ihn trifft")
    func nearDuplicatesAreDropped() {
        // 16:32 + 30 min = 17:05 after rounding, which is inside the ten-minute
        // window around 17:00 — offering both would be two buttons for one time.
        let suggestions = RevisitPlanner.suggestions(now: date(16, 32), calendar: calendar)
        #expect(!suggestions.contains { $0.kind == .clock(hour: 17, minute: 0) })
    }

    @Test("Relative Vorschläge werden auf fünf Minuten aufgerundet")
    func relativeOffsetsAreRounded() {
        let suggestions = RevisitPlanner.suggestions(now: date(13, 12), calendar: calendar)
        let inThirty = try! #require(suggestions.first { $0.kind == .relative(minutes: 30) })

        // 13:12 + 30 = 13:42 → 13:45, a time a person would actually say.
        #expect(calendar.component(.hour, from: inThirty.date) == 13)
        #expect(calendar.component(.minute, from: inThirty.date) == 45)
    }

    @Test("Der freie Zeitwähler startet auf dem ersten Vorschlag")
    func defaultTimeMatchesFirstSuggestion() {
        let now = date(13, 12)
        #expect(RevisitPlanner.defaultTime(now: now, calendar: calendar)
                == RevisitPlanner.suggestions(now: now, calendar: calendar).first?.date)
    }
}

// MARK: - The list chip

@Suite("Später — Anzeige in der Liste")
struct RevisitGlanceTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func now() -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 14, minute: 0))!
    }

    private func glance(minutesFromNow: Int, doors: Int = 1) -> RevisitGlance? {
        RevisitGlance.make(
            at: now().addingTimeInterval(TimeInterval(minutesFromNow * 60)),
            laterDoors: doors,
            now: now(),
            calendar: calendar
        )
    }

    @Test("Ohne gebuchte Zeit gibt es keinen Chip")
    func noTimeNoChip() {
        #expect(RevisitGlance.make(at: nil, laterDoors: 0, now: now()) == nil)
    }

    @Test("Innerhalb einer Stunde wird in Minuten gezählt")
    func countsMinutesWhenClose() {
        #expect(glance(minutesFromNow: 25)?.label == "in 25 Min")
        #expect(glance(minutesFromNow: 25)?.urgency == .imminent)
    }

    /// The whole point of the chip: past the booked minute it must stop reading like
    /// a plan and start reading like a debt.
    @Test("Eine verstrichene Zeit ist überfällig, nicht „um 13:48“")
    func pastTimeIsOverdue() {
        #expect(glance(minutesFromNow: -12)?.label == "12 Min überfällig")
        #expect(glance(minutesFromNow: -12)?.urgency == .overdue)
        #expect(glance(minutesFromNow: -180)?.label == "überfällig")
    }

    @Test("Ab einer Stunde steht die Uhrzeit da")
    func showsClockTimeWhenFarOut() {
        #expect(glance(minutesFromNow: 120)?.label == "um 16:00")
        #expect(glance(minutesFromNow: 120)?.urgency == .upcoming)
    }

    @Test("Ein anderer Tag wird benannt")
    func namesAnotherDay() {
        #expect(glance(minutesFromNow: 20 * 60)?.label == "morgen 10:00")
    }

    /// Several booked doors in one house collapse to the earliest plus a counter —
    /// the row has space for one time, not four.
    @Test("Weitere gebuchte Türen erscheinen als Zähler")
    func countsAdditionalDoors() {
        #expect(glance(minutesFromNow: 30, doors: 3)?.extraDoors == 2)
        #expect(glance(minutesFromNow: 30, doors: 1)?.extraDoors == 0)
    }
}
