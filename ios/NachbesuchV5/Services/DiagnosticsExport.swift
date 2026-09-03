import Foundation

/// One-file health report for a failing device elsewhere (B11): app version,
/// system, store health and work counts — and provably **no donor data**: no
/// addresses, no notes, no coordinates, no territory names. Counts only.
nonisolated enum DiagnosticsExport {
    struct Counts: Sendable {
        let territories: Int
        let houses: Int
        let doors: Int
        let recordedDoors: Int
    }

    static func makeText(
        counts: Counts,
        autoBackup: String?,
        storeSizeKB: Int?,
        system: String,
        model: String,
        now: Date = .now
    ) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "Nachbesuch-Diagnose",
            "Erstellt: \(now.formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "de_AT"))))",
            "App: \(version) (\(build))",
            "System: \(system), \(model)",
            "Gebiete: \(counts.territories)",
            "Häuser: \(counts.houses)",
            "Türen: \(counts.doors), davon eingetragen: \(counts.recordedDoors)",
        ]
        if let storeSizeKB {
            lines.append("Datenspeicher: vorhanden, \(storeSizeKB) KB")
        } else {
            lines.append("Datenspeicher: nicht lesbar")
        }
        lines.append("Letzte automatische Sicherung: \(autoBackup ?? "noch keine")")
        lines.append("Enthält keine Adressen, Notizen, Koordinaten oder Gebietsnamen.")
        return lines.joined(separator: "\n")
    }

    static func writeFile(_ text: String) throws -> URL {
        let url = try ExportScratch.makeURL(fileName: "Nachbesuch-Diagnose.txt")
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
