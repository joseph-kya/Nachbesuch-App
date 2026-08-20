#if DEBUG
import Foundation
import Testing
@testable import NachbesuchV5

/// Writes a representative report to disk so the layout can be inspected by eye.
/// Enabled only when NACHBESUCH_DUMP_PDF is set, so it never runs in a normal pass.
@Suite("PDF-Vorschau")
@MainActor
struct PDFDumpTests {

    /// Skipped — not failed — unless the harness asks for it.
    @Test(
        "Beispielbericht schreiben",
        .enabled(if: ProcessInfo.processInfo.environment["NACHBESUCH_DUMP_PDF"] != nil)
    )
    func dumpSample() async throws {
        let gebiet = Gebiet(name: "Ottakring", districtOrCity: "1160 Wien")
        var houses: [House] = []

        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 9, minute: 12)) ?? .now
        var minute = 0.0

        func stamped(_ label: String, _ outcome: VisitOutcome?, step: Double = 4) -> DoorResult {
            minute += step
            return DoorResult(
                label: label,
                outcome: outcome,
                updatedAt: outcome == nil ? nil : base.addingTimeInterval(minute * 60)
            )
        }

        func add(_ address: String, _ doors: [DoorResult], note: String = "") {
            let house = House(
                address: address, latitude: 48.21, longitude: 16.31,
                gebietID: gebiet.id,
                isApartmentBuilding: doors.count > 1,
                unitCount: max(doors.count, 1)
            )
            house.note = note
            house.restore(units: doors)
            houses.append(house)
        }

        add("Thaliastraße 12", [stamped("Haushalt", .joined)])
        add("Thaliastraße 14", [stamped("Haushalt", .notHome)],
            note: "Abends wiederkommen, Klingel defekt")
        add("Thaliastraße 16", [stamped("Haushalt", .earlyNo)])
        add("Thaliastraße 18", [stamped("Haushalt", nil)])   // nie besucht → fällt raus
        add("Hasnerstraße 9", [
            stamped("Tür 1", .joined, step: 2),
            stamped("Tür 2", .notHome, step: 1),
            stamped("Tür 3", .lateNo, step: 1),
            stamped("Tür 4", nil),
            stamped("Tür 5", nil),
            stamped("Tür 6", nil)
        ], note: "Hinterhaus separat")
        add("Hasnerstraße 11", [stamped("Haushalt", .joined)])
        for number in stride(from: 2, through: 40, by: 2) {
            add("Wattgasse \(number)", [
                stamped("Haushalt", number % 3 == 0 ? .notHome : .joined)
            ])
        }

        let document = await DayExportService.makeDocument(
            gebiet: gebiet, houses: houses, scope: .combined, options: ExportOptions()
        )
        let url = try DayExportService.makePDF(document)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("nachbesuch-sample.pdf")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        print("[PDFDump] \(destination.path)")
        print("[PDFDump-TEXT]\n\(DayExportService.makeText(document))")
    }
}
#endif
