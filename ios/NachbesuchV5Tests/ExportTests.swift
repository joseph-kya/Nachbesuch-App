import Foundation
import Testing
@testable import NachbesuchV5

@Suite("Export")
@MainActor
struct ExportTests {

    private func makeGebiet() -> Gebiet {
        Gebiet(name: "Ottakring", districtOrCity: "1160 Wien")
    }

    @discardableResult
    private func addHouse(
        to gebiet: Gebiet,
        address: String,
        doors: [DoorResult],
        note: String = ""
    ) -> House {
        let house = House(
            address: address,
            latitude: 48.21, longitude: 16.31,
            gebietID: gebiet.id,
            isApartmentBuilding: doors.count > 1,
            unitCount: max(doors.count, 1)
        )
        house.note = note
        house.restore(units: doors)
        return house
    }

    /// The headline requirement: a report is a record of work done, not a dump of
    /// every address in the territory.
    @Test("Nur besuchte Adressen landen im Export")
    func visitedOnlyDropsUntouchedHouses() async {
        let gebiet = makeGebiet()
        let houses = [
            addHouse(to: gebiet, address: "Thaliastraße 1", doors: [DoorResult(label: "Haushalt", outcome: .joined)]),
            addHouse(to: gebiet, address: "Thaliastraße 3", doors: [DoorResult(label: "Haushalt")]),
            addHouse(to: gebiet, address: "Thaliastraße 5", doors: [DoorResult(label: "Haushalt", outcome: .notHome)])
        ]

        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: houses, scope: .combined, options: ExportOptions()
        )

        #expect(document.includedHouses == 2)
        #expect(document.totalHouses == 3)
        let addresses = document.houses.map(\.address)
        #expect(!addresses.contains("Thaliastraße 3"), "Ein Haus ohne jeden Eintrag gehört nicht in den Bericht")
        #expect(document.summary.houses == 2)
    }

    @Test("Abschalten der Filterung nimmt wieder alles auf")
    func optOutIncludesEverything() async {
        let gebiet = makeGebiet()
        let houses = [
            addHouse(to: gebiet, address: "Thaliastraße 1", doors: [DoorResult(label: "Haushalt", outcome: .joined)]),
            addHouse(to: gebiet, address: "Thaliastraße 3", doors: [DoorResult(label: "Haushalt")])
        ]
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: houses, scope: .combined,
            options: ExportOptions(visitedOnly: false, includeNotes: true)
        )
        #expect(document.includedHouses == 2)
    }

    @Test("Passanten erscheinen im Export")
    func passantenAppearInExport() async {
        let gebiet = makeGebiet()
        let passant = Passant(note: "Frau mit Hund", latitude: 48.2, longitude: 16.3, gebietID: gebiet.id)
        passant.outcome = .joined
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [], scope: .combined, options: ExportOptions(), passanten: [passant]
        )
        #expect(!document.isEmpty)
        #expect(document.passanten.count == 1)
        let text = DayExportService.makeText(document)
        #expect(text.contains("Frau mit Hund"))
        #expect(text.contains(VisitOutcome.joined.title))
    }

    /// A building where three of eight doors were answered should say so — and list
    /// only those three, not five "Offen" rows.
    @Test("Mehrparteienhäuser listen nur die beantworteten Türen")
    func apartmentListsAnsweredDoorsOnly() async {
        let gebiet = makeGebiet()
        let doors = [
            DoorResult(label: "Tür 1", outcome: .joined),
            DoorResult(label: "Tür 2", outcome: .notHome),
            DoorResult(label: "Tür 3"),
            DoorResult(label: "Tür 4")
        ]
        let house = addHouse(to: gebiet, address: "Hasnerstraße 9", doors: doors)
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [house], scope: .combined, options: ExportOptions()
        )
        let exported = document.houses.first
        #expect(exported?.result == "2 von 4 Türen")
        #expect(exported?.doors.count == 2)
        #expect(exported?.doors.map(\.label) == ["Tür 1", "Tür 2"])
    }

    /// A "Tag 2" report must not list a door settled on day 1 and never revisited.
    @Test("Tag-2-Export enthält nur echte Zweitbesuche")
    func day2ExportIsStrict() async {
        let gebiet = Gebiet(name: "Ottakring", isTwoDay: true)
        let houses = [
            addHouse(to: gebiet, address: "Thaliastraße 1", doors: [DoorResult(label: "Haushalt", outcome: .joined)]),
            addHouse(to: gebiet, address: "Thaliastraße 3",
                     doors: [DoorResult(label: "Haushalt", outcome: .notHome, day2Outcome: .lateNo)])
        ]
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: houses, scope: .day2, options: ExportOptions()
        )
        let addresses = document.houses.map(\.address)
        #expect(addresses == ["Thaliastraße 3"])
        #expect(document.summary.lateNo == 1)
        #expect(document.summary.joined == 0)
    }

    @Test("Notizen lassen sich weglassen")
    func notesCanBeExcluded() async {
        let gebiet = makeGebiet()
        let house = addHouse(
            to: gebiet, address: "Thaliastraße 1",
            doors: [DoorResult(label: "Haushalt", outcome: .joined)],
            note: "Hund"
        )
        let with = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [house], scope: .combined,
            options: ExportOptions(visitedOnly: true, includeNotes: true)
        )
        #expect(with.houses.first?.note == "Hund")

        let without = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [house], scope: .combined,
            options: ExportOptions(visitedOnly: true, includeNotes: false)
        )
        #expect(without.houses.first?.note.isEmpty == true)
    }

    /// The report should read as the round you actually walked.
    @Test("Der Export folgt der Uhrzeit der Eintragungen")
    func ordersChronologically() async throws {
        let gebiet = makeGebiet()
        let calendar = Calendar.current
        let base = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 9)))

        func house(_ address: String, minutesLater: Int) -> House {
            let door = DoorResult(
                label: "Haushalt",
                outcome: .joined,
                updatedAt: base.addingTimeInterval(Double(minutesLater) * 60)
            )
            return addHouse(to: gebiet, address: address, doors: [door])
        }

        // Deliberately added out of order, and alphabetically the reverse.
        let houses = [
            house("Wattgasse 2", minutesLater: 30),
            house("Ahorngasse 1", minutesLater: 90),
            house("Mittelgasse 5", minutesLater: 60)
        ]

        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: houses, scope: .combined, options: ExportOptions()
        )
        #expect(document.houses.map(\.address) == ["Wattgasse 2", "Mittelgasse 5", "Ahorngasse 1"])
    }

    /// The time drives the order but must not appear in the output.
    @Test("Die Uhrzeit selbst wird nicht exportiert")
    func timeIsNotPrinted() async throws {
        let gebiet = makeGebiet()
        let calendar = Calendar.current
        let stamp = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 14, minute: 37)))
        let house = addHouse(
            to: gebiet, address: "Thaliastraße 1",
            doors: [DoorResult(label: "Haushalt", outcome: .joined, updatedAt: stamp)]
        )
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [house], scope: .combined, options: ExportOptions()
        )
        #expect(document.houses.first?.recordedAt != nil, "Die Zeit steuert die Sortierung")

        let text = DayExportService.makeText(document)
        #expect(!text.contains("14:37"))
        #expect(!text.contains("37"))
    }

    /// A summary listing "Spätes Nein: 0" is noise.
    @Test("Die Zusammenfassung zeigt nur vorgekommene Ergebnisse")
    func summarySkipsZeroes() async {
        let gebiet = makeGebiet()
        let house = addHouse(to: gebiet, address: "Thaliastraße 1",
                             doors: [DoorResult(label: "Haushalt", outcome: .joined)])
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [house], scope: .combined, options: ExportOptions()
        )
        let labels = document.summary.lines.map(\.label)
        #expect(labels.contains(VisitOutcome.joined.title))
        #expect(!labels.contains(VisitOutcome.lateNo.title))
    }

    @Test("Der Textexport bleibt knapp und ohne Emoji")
    func textIsConcise() async {
        let gebiet = makeGebiet()
        let house = addHouse(to: gebiet, address: "Thaliastraße 1",
                             doors: [DoorResult(label: "Haushalt", outcome: .joined)])
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [house], scope: .combined, options: ExportOptions()
        )
        let text = DayExportService.makeText(document)
        #expect(text.contains("Ottakring"))
        #expect(text.contains("Thaliastraße 1"))
        #expect(text.contains("Dabei"))
        for outcome in VisitOutcome.allCases {
            #expect(!text.contains(outcome.emoji), "Emoji gehören nicht in einen Bericht")
        }
        #expect(!text.contains("VOLKSHILFE"))
    }

    @Test("Legacy-Export gruppiert Straßen und nutzt Statussymbole")
    func legacyTextMatchesFieldList() async {
        let gebiet = makeGebiet()
        let houses = [
            addHouse(to: gebiet, address: "Neugasse 3", doors: [DoorResult(label: "Haushalt", outcome: .earlyNo)]),
            addHouse(to: gebiet, address: "Neugasse 7", doors: [DoorResult(label: "Haushalt", outcome: .notHome)]),
            addHouse(to: gebiet, address: "Hubertusstraße 44", doors: [
                DoorResult(label: "Tür 1", outcome: .notHome),
                DoorResult(label: "Tür 2", outcome: .joined)
            ])
        ]
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: houses, scope: .combined, options: ExportOptions()
        )
        let legacy = DayExportService.makeLegacyText(document)
        #expect(legacy.contains("Neugasse 3🚫 7🔴"))
        #expect(legacy.contains("Hubertusstraße 44:\n1🔴 2❤️‍🔥"))
        #expect(!legacy.contains("Notiz:"))
    }

    @Test("Leerer Export sagt das klar und erzeugt kein PDF-Gerüst")
    func emptyExportIsExplicit() async {
        let gebiet = makeGebiet()
        let house = addHouse(to: gebiet, address: "Thaliastraße 1", doors: [DoorResult(label: "Haushalt")])
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: [house], scope: .combined, options: ExportOptions()
        )
        #expect(document.isEmpty)
        #expect(DayExportService.makeText(document).contains("noch kein Haus besucht"))
    }

    @Test("Das PDF entsteht und ist mehrseitig paginiert")
    func pdfRenders() async throws {
        let gebiet = makeGebiet()
        var houses: [House] = []
        for street in 1...6 {
            for number in 1...20 {
                houses.append(addHouse(
                    to: gebiet,
                    address: "Teststraße \(street) \(number)",
                    doors: [DoorResult(label: "Haushalt", outcome: .joined)]
                ))
            }
        }
        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: houses, scope: .combined, options: ExportOptions()
        )
        let url = try DayExportService.makePDF(document)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(data.count > 1000)
        #expect(data.starts(with: Array("%PDF".utf8)))
        // Page numbering needs the total, which needs a full measuring pass first.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("/Count"), "Das Dokument hat einen Seitenbaum")
    }
}
