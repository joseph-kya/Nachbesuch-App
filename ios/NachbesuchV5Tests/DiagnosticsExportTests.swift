import Foundation
import Testing
@testable import NachbesuchV5

/// The diagnostics export (B11) must provably contain no donor data: no
/// addresses, no notes, no coordinates, no territory names. Counts only.
@Suite("Diagnose-Export")
struct DiagnosticsExportTests {
    @Test func containsCountsAndNoDonorData() {
        let text = DiagnosticsExport.makeText(
            counts: .init(territories: 2, houses: 40, doors: 120, recordedDoors: 75),
            autoBackup: "heute, 08:12",
            storeSizeKB: 512,
            system: "iOS 18.5",
            model: "iPhone"
        )
        #expect(text.contains("Gebiete: 2"))
        #expect(text.contains("Häuser: 40"))
        #expect(text.contains("Türen: 120, davon eingetragen: 75"))
        #expect(text.contains("heute, 08:12"))
        // The address, note, coordinate and name a careless interpolation
        // would leak — none of them may appear.
        #expect(!text.contains("Geheimstraße"))
        #expect(!text.contains("Hund"))
        #expect(!text.contains("48.2"))
        #expect(!text.contains("Klagenfurt"))
    }

    @Test func missingStoreAndBackupReadHonestly() {
        let text = DiagnosticsExport.makeText(
            counts: .init(territories: 0, houses: 0, doors: 0, recordedDoors: 0),
            autoBackup: nil,
            storeSizeKB: nil,
            system: "iOS 18.5",
            model: "iPhone"
        )
        #expect(text.contains("nicht lesbar"))
        #expect(text.contains("noch keine"))
    }
}
