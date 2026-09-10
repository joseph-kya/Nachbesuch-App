import Foundation
import SwiftData
import os

/// The automatic daily safety backup (next-steps B1).
///
/// The entire risk story of this project is "one device, one copy", and the
/// manual menu item relies on a human remembering to tap it. This runs at most
/// once per calendar day on launch, entirely off the main actor, into the
/// Files-visible documents directory (picked up by the owner's device backup),
/// keeping the last 7 and deleting older ones. Failures are silent in the UI
/// but logged — a backup that nags is a backup that gets turned off.
@ModelActor
actor AutoBackupService {
    /// Files kept; anything older is deleted after a successful write.
    private static let keptFiles = 7
    private static let lastRunDayKey = "autobackup.lastRunDay"
    private static let filePrefix = "Nachbesuch-Auto-"

    private static let log = Logger(
        subsystem: "at.volkshilfe.nachbesuch",
        category: "autobackup"
    )

    /// Runs the backup unless one already ran today. Never throws and never
    /// touches the main actor beyond the call itself.
    func runIfNeeded() async {
        let today = Self.dayString(Date.now)
        guard UserDefaults.standard.string(forKey: Self.lastRunDayKey) != today else { return }
        do {
            let gebietSnapshots = try fetchGebietSnapshots()
            let houseSnapshots = try fetchHouseSnapshots()
            let passantSnapshots = try fetchPassantSnapshots()
            // An empty store backs up nothing — and must not stamp the day,
            // or a launch that raced the seeding would block the real backup
            // until tomorrow.
            guard !gebietSnapshots.isEmpty || !houseSnapshots.isEmpty || !passantSnapshots.isEmpty else { return }
            // Codierung im Hintergrund: Die Sicherung darf Pins/Scrolls keine CPU
            // wegnehmen — manuell bleibt userInitiated, automatisch background.
            let data = try await BackupService.encodeBackup(
                gebietSnapshots: gebietSnapshots,
                houseSnapshots: houseSnapshots,
                passantSnapshots: passantSnapshots,
                priority: .background
            )
            guard !Task.isCancelled else { return }
            let url = try write(data: data, day: today)
            prune(keeping: url)
            // Stamped only after the write survived: a crash mid-write must
            // retry on the next launch, not skip a day.
            UserDefaults.standard.set(today, forKey: Self.lastRunDayKey)
            Self.log.info("Automatische Sicherung geschrieben: \(url.lastPathComponent, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Automatische Sicherung fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The newest automatic backup, if any — for the „Letzte automatische
    /// Sicherung" row in Archiv → Sicherung. Synchronous and cheap (at most a
    /// handful of files); safe to call from a view task.
    nonisolated static func latest() -> (date: Date, url: URL)? {
        let files = backupFiles()
        guard let newest = files.first else { return nil }
        let values = try? newest.resourceValues(forKeys: [.creationDateKey])
        return (values?.creationDate ?? .distantPast, newest)
    }

    nonisolated static func describe(date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_AT")))
        if calendar.isDateInToday(date) { return "heute, \(time)" }
        if calendar.isDateInYesterday(date) { return "gestern, \(time)" }
        let day = date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "de_AT")))
        return "\(day), \(time)"
    }

    // MARK: - Private

    private func fetchGebietSnapshots() throws -> [BackupService.GebietSnapshot] {
        var result: [BackupService.GebietSnapshot] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<Gebiet>(), batchSize: 200) { gebiet in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(BackupService.GebietSnapshot(gebiet))
        }
        return result
    }

    private func fetchHouseSnapshots() throws -> [BackupService.HouseSnapshot] {
        var result: [BackupService.HouseSnapshot] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<House>(), batchSize: 200) { house in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(BackupService.HouseSnapshot(house))
        }
        return result
    }

    private func fetchPassantSnapshots() throws -> [BackupService.PassantSnapshot] {
        var result: [BackupService.PassantSnapshot] = []
        var visited = 0
        try modelContext.enumerate(FetchDescriptor<Passant>(), batchSize: 200) { passant in
            if visited.isMultiple(of: 64) { try Task.checkCancellation() }
            visited += 1
            result.append(BackupService.PassantSnapshot(passant))
        }
        return result
    }

    private func write(data: Data, day: String) throws -> URL {
        let directory = try Self.documentsDirectory()
        let url = directory.appendingPathComponent("\(Self.filePrefix)\(day).json", isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func prune(keeping latest: URL) {
        let files = Self.backupFiles().filter { $0 != latest }
        guard files.count + 1 > Self.keptFiles else { return }
        for stale in files.dropFirst(Self.keptFiles - 1) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    nonisolated private static func documentsDirectory() throws -> URL {
        let url = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return url
    }

    /// Newest first. The day stamp in the name sorts lexically, so no file
    /// attributes are needed to order them.
    nonisolated private static func backupFiles() -> [URL] {
        guard let directory = try? documentsDirectory() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    nonisolated private static func dayString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
