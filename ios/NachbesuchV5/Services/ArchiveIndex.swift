import Foundation

/// Precomputed, searchable summary of every territory.
///
/// Built off the main actor and keyed so it only rebuilds when the data actually
/// changed. Door labels are deliberately **not** indexed: they are "Tür 1"…"Tür N",
/// they were the largest allocation in the whole index (one `IndexedText` per door
/// in the entire database, retained for the tab's lifetime), and nobody searches them.
nonisolated struct ArchiveEntry: Sendable {
    let gebietID: UUID
    let houseCount: Int
    let overall: OutcomeTally
    let day1: OutcomeTally
    let day2: OutcomeTally
    let pendingRevisits: Int
    let revisitTargets: Int
    let damagedHouseCount: Int
    /// Folded haystack: name, place, notes, every address and house note.
    let searchText: String
    /// Folded date words: "heute", weekday, month name, numeric forms.
    let dateText: String
    let day1Date: Date
    let day2Date: Date?

    init(
        gebietID: UUID,
        houseCount: Int,
        overall: OutcomeTally,
        day1: OutcomeTally,
        day2: OutcomeTally,
        pendingRevisits: Int,
        revisitTargets: Int = 0,
        damagedHouseCount: Int = 0,
        searchText: String,
        dateText: String,
        day1Date: Date,
        day2Date: Date?
    ) {
        self.gebietID = gebietID
        self.houseCount = houseCount
        self.overall = overall
        self.day1 = day1
        self.day2 = day2
        self.pendingRevisits = pendingRevisits
        self.revisitTargets = revisitTargets
        self.damagedHouseCount = damagedHouseCount
        self.searchText = searchText
        self.dateText = dateText
        self.day1Date = day1Date
        self.day2Date = day2Date
    }

    var isComplete: Bool { overall.unitCount > 0 && overall.open == 0 }
}

nonisolated struct ArchiveIndex: Sendable {
    var entries: [UUID: ArchiveEntry]

    static let empty = ArchiveIndex(entries: [:])

    var isEmpty: Bool { entries.isEmpty }

    func entry(for id: UUID) -> ArchiveEntry? { entries[id] }
}

nonisolated enum ArchiveIndexBuilder {
    struct GebietSeed: Sendable {
        let id: UUID
        let name: String
        let districtOrCity: String
        let notes: String
        let day1Date: Date
        let day2Date: Date?
        let isTwoDay: Bool
    }

    struct HouseSeed: Sendable {
        let gebietID: UUID?
        let address: String
        let note: String
        let unitsData: Data
    }

    static func build(gebiete: [GebietSeed], houses: [HouseSeed]) -> ArchiveIndex {
        let trace = PerformanceTrace.begin("Build archive index")
        defer { PerformanceTrace.end("Build archive index", id: trace) }

        let decoder = AppCoders.unitsDecoder()

        final class Accumulator {
            var houseCount = 0
            var overall = OutcomeTally.empty
            var day1 = OutcomeTally.empty
            var day2 = OutcomeTally.empty
            var pendingRevisits = 0
            var revisitTargets = 0
            var damagedHouseCount = 0
            var text = ""
        }

        // Reference type: the previous version copied a struct with three growing
        // arrays out of a dictionary and back in for every house, which retained and
        // released three array buffers per iteration.
        var accumulators: [UUID: Accumulator] = [:]
        accumulators.reserveCapacity(gebiete.count)
        for gebiet in gebiete { accumulators[gebiet.id] = Accumulator() }

        for house in houses {
            guard let gebietID = house.gebietID, let accumulator = accumulators[gebietID] else { continue }
            accumulator.houseCount += 1
            accumulator.text += " " + house.address
            if !house.note.isEmpty { accumulator.text += " " + house.note }

            let state = HouseDataState.decode(house.unitsData, decoder: decoder)
            guard let doors = state.doors else {
                accumulator.damagedHouseCount += 1
                continue
            }
            for door in doors {
                accumulator.overall.ingest(door, scope: .combined)

                accumulator.day1.unitCount += 1
                if let result = door.result(on: 1) {
                    accumulator.day1.completed += 1
                    accumulator.day1.add(result)
                } else {
                    accumulator.day1.open += 1
                }

                let isRevisitTarget = door.outcome == .notHome || door.outcome == nil || door.day2Outcome != nil
                guard isRevisitTarget else { continue }
                accumulator.revisitTargets += 1
                accumulator.day2.unitCount += 1
                if let result = door.result(on: 2) {
                    accumulator.day2.completed += 1
                    accumulator.day2.add(result)
                } else if door.isPendingRevisit {
                    accumulator.day2.open += 1
                    accumulator.pendingRevisits += 1
                }
            }
        }

        var entries: [UUID: ArchiveEntry] = [:]
        entries.reserveCapacity(gebiete.count)
        for gebiet in gebiete {
            let accumulator = accumulators[gebiet.id] ?? Accumulator()
            let haystack = "\(gebiet.name) \(gebiet.districtOrCity) \(gebiet.notes)\(accumulator.text)"
            entries[gebiet.id] = ArchiveEntry(
                gebietID: gebiet.id,
                houseCount: accumulator.houseCount,
                overall: accumulator.overall,
                day1: accumulator.day1,
                day2: accumulator.day2,
                pendingRevisits: accumulator.pendingRevisits,
                revisitTargets: accumulator.revisitTargets,
                damagedHouseCount: accumulator.damagedHouseCount,
                searchText: SearchText.fold(haystack),
                dateText: dateText(day1: gebiet.day1Date, day2: gebiet.day2Date),
                day1Date: gebiet.day1Date,
                day2Date: gebiet.day2Date
            )
        }
        return ArchiveIndex(entries: entries)
    }

    private static let austrianLocale = Locale(identifier: "de_AT")
    private static let weekdayStyle = Date.FormatStyle.dateTime.weekday(.wide).locale(austrianLocale)
    private static let monthStyle = Date.FormatStyle.dateTime.month(.wide).locale(austrianLocale)

    /// Everything a user might type to mean this date.
    private static func dateText(day1: Date, day2: Date?) -> String {
        var parts: [String] = []
        for date in [day1, day2].compactMap({ $0 }) {
            let calendar = Gebiet.campaignCalendar
            let components = calendar.dateComponents([.day, .month, .year], from: date)
            let day = components.day ?? 1
            let month = components.month ?? 1
            let year = components.year ?? calendar.component(.year, from: date)
            parts.append(date.formatted(weekdayStyle))
            parts.append(date.formatted(monthStyle))
            parts.append("\(day).\(month).")
            parts.append(String(format: "%02d.%02d.%04d", day, month, year))
            parts.append("\(year)")
            if calendar.isDateInToday(date) { parts.append("heute") }
            if calendar.isDateInYesterday(date) { parts.append("gestern") }
            if calendar.isDateInTomorrow(date) { parts.append("morgen") }
        }
        return SearchText.fold(parts.joined(separator: " "))
    }
}
