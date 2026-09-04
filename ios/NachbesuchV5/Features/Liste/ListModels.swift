import CoreLocation
import Foundation

/// A row, as a pure value.
///
/// Deliberately holds no `House` reference. The old row model carried a live
/// `@Model` object, which made it impossible for SwiftUI to diff a row away: any
/// change to any house invalidated every row in the list.
nonisolated struct HouseRowModel: Identifiable, Equatable, Sendable {
    let id: UUID
    let address: String
    let note: String
    let street: String
    /// The door's own name — "6", "12a/3" — when the address has one.
    let houseNumber: String?
    /// The address without the postal code and the city.
    let shortAddress: String
    let markerOutcome: VisitOutcome?
    let unitCount: Int
    let completedCount: Int
    let followUpCount: Int
    let joinedCount: Int
    /// Doors set to "Später" in this scope. Kept separate from `followUpCount`
    /// ("Niemand da"): both mean come back, only this one names an hour.
    let laterCount: Int
    let openCount: Int
    let createdAt: Date
    let searchText: String
    let latitude: Double
    let longitude: Double
    /// When the most recent door of this house was recorded.
    let recordedAt: Date?
    /// The earliest return time booked on this house, when any door is "Später".
    let nextRevisitAt: Date?
    /// Metres from the user, when a position is known.
    var distance: Double?

    var isSingleDoor: Bool { unitCount == 1 }

    var formattedDistance: String? {
        guard let distance else { return nil }
        if distance < 950 { return "\(Int((distance / 10).rounded() * 10)) m" }
        return String(format: "%.1f km", distance / 1000)
    }

    /// What the row leads with.
    ///
    /// The street is already the section header directly above, so the row says the
    /// number and nothing else. The full string this replaces — "Am Sonnenhang 6,
    /// 9210 Pörtschach am Wörthersee" — repeated the header, then added a postal
    /// code and a city identical for every address in the territory, and the two
    /// lines it wrapped onto were what made four addresses fill a screen.
    ///
    /// The full address is still what VoiceOver reads and what the undo banner and
    /// the export name, so nothing is lost — it is only not *drawn* four times.
    var title: String { houseNumber ?? shortAddress }

    /// What is *there*, never what is left — the trailing badge is the one place
    /// the open count belongs, and it was written here too.
    ///
    /// `nil` when there is nothing to say. A fresh territory has no result on any
    /// door, and "Noch kein Status" under every single row is the dashed grey glyph
    /// beside it spelled out: the same fact, in the widest possible form, on the
    /// screen the most times. Without it an untouched row is one line tall.
    ///
    /// The pair this replaces read "5/6 Türen · 3 offen", which is two different
    /// definitions of finished in one line: 5 of 6 doors are *recorded*, and 3 of
    /// them still want a second visit. Six doors, five recorded, three open is a
    /// true sentence and an unreadable one at a doorstep.
    var subtitle: String? {
        var parts: [String] = []
        if isSingleDoor {
            // Only a real result. The absence of one is the glyph's job.
            if let markerOutcome { parts.append(markerOutcome.title) }
        } else {
            parts.append("\(unitCount) Türen")
        }
        // The booked return time used to be appended here as "· zurück um 18:30",
        // buried in grey caption text between two other facts. It is now a tinted
        // chip of its own — `RevisitGlance` — so the subtitle is back to the plain
        // "when was this last touched" stamp and the two stop competing.
        if let recordedAt {
            parts.append(recordedAt.formatted(date: .omitted, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver reads instead of an emoji. The return time is spoken by the
    /// chip's own label, so it is deliberately absent here.
    var accessibilityValue: String {
        if isSingleDoor { return markerOutcome.displayTitleValue }
        return openCount > 0
            ? "\(unitCount) Türen, \(openCount) offen"
            : "\(unitCount) Türen, fertig"
    }
}

extension Optional where Wrapped == VisitOutcome {
    nonisolated var displayTitleValue: String { self?.title ?? "Noch kein Status" }
}

nonisolated enum ListFilter: String, CaseIterable, Identifiable, Sendable {
    case all, open, later, unanswered, joined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Alle"
        case .open: "Offen"
        case .later: "Später"
        case .unanswered: "Ohne Status"
        case .joined: "Dabei"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "list.bullet"
        case .open: "arrow.clockwise"
        case .later: "clock.fill"
        case .unanswered: "questionmark.circle"
        case .joined: "heart.fill"
        }
    }

    var tint: String {
        switch self {
        case .all: "secondary"
        case .open: "red"
        case .later: "indigo"
        case .unanswered: "orange"
        case .joined: "pink"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "Noch keine Häuser"
        case .open: "Keine offenen Nachbesuche"
        case .later: "Nichts eingeplant"
        case .unanswered: "Alles eingetragen"
        case .joined: "Noch keine Beitritte"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Füge auf der Karte dein erstes Haus hinzu."
        case .open: "Für diesen Zeitraum ist nichts mehr offen."
        case .later: "Häuser mit einer gebuchten Uhrzeit erscheinen hier — nach Zeit gereiht."
        case .unanswered: "Jeder erfasste Haushalt hat bereits einen Status."
        case .joined: "Hier erscheinen Haushalte, die dabei sind."
        }
    }

    func matches(_ row: HouseRowModel) -> Bool {
        switch self {
        case .all: true
        case .open: row.openCount > 0
        case .later: row.laterCount > 0
        case .unanswered: row.completedCount < row.unitCount
        case .joined: row.joinedCount > 0
        }
    }
}

/// One street's worth of rows.
nonisolated struct StreetSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let rows: [HouseRowModel]
    let houseCount: Int
    let unitCount: Int
    let completedCount: Int
    let openCount: Int

    /// Doors with nothing left to do on them.
    ///
    /// **Not** `completedCount`. A door counts as *completed* the moment an outcome
    /// is written on it, and two of those outcomes — "Niemand da" and "Später" —
    /// mean come back. So a street could read a green-looking 68/80 while 40 of its
    /// 80 doors were still work, and the bar beside it showed 85 %. This is the
    /// figure that answers the only question the list is asked: how much of this
    /// street is left?
    var settledCount: Int { max(unitCount - openCount, 0) }

    var isDone: Bool { unitCount > 0 && openCount == 0 }

    var progress: Double {
        unitCount > 0 ? Double(settledCount) / Double(unitCount) : 0
    }
}

/// Builds the list corpus once per data change, off the main actor.
nonisolated enum HouseListBuilder {
    /// Coordinate-free house input.
    struct Seed: Sendable {
        let id: UUID
        let address: String
        let note: String
        let createdAt: Date
        let unitsData: Data
        let latitude: Double
        let longitude: Double
    }

    static func rows(from seeds: [Seed], scope: DayScope) -> [HouseRowModel] {
        let decoder = AppCoders.unitsDecoder()
        return seeds.map { seed in
            let doors = (try? decoder.decode([DoorResult].self, from: seed.unitsData)) ?? []
            let tally = OutcomeTally.tally(doors, scope: scope)
            let recordedAt = doors.compactMap { $0.timestamp(in: scope) }.max()
            let street = StreetNameParser.street(from: seed.address)
            var searchable = "\(seed.address) \(seed.note) \(street)"
            for door in doors { searchable += " \(door.label)" }
            return HouseRowModel(
                id: seed.id,
                address: seed.address,
                note: seed.note,
                street: street,
                houseNumber: StreetNameParser.houseNumber(from: seed.address),
                shortAddress: StreetNameParser.withoutLocality(seed.address),
                markerOutcome: OutcomeTally.markerOutcome(for: doors, scope: scope),
                unitCount: doors.count,
                completedCount: tally.completed,
                followUpCount: tally.notHome,
                joinedCount: tally.joined,
                laterCount: tally.later,
                openCount: tally.open,
                createdAt: seed.createdAt,
                searchText: SearchText.fold(searchable),
                latitude: seed.latitude,
                longitude: seed.longitude,
                recordedAt: recordedAt,
                nextRevisitAt: doors.compactMap { $0.displayRevisitAt(in: scope) }.min()
            )
        }
    }

    static func filter(_ rows: [HouseRowModel], filter: ListFilter, query: String) -> [HouseRowModel] {
        let tokens = SearchText.tokenize(query)
        var result = rows
        if !tokens.isEmpty {
            result = result.filter { row in
                tokens.allSatisfy { row.searchText.contains($0) }
            }
        }
        return filter == .all ? result : result.filter(filter.matches)
    }

    /// Soonest appointment first, and overdue ones therefore at the very top.
    ///
    /// Only meaningful under the "Später" filter, where every row has a booked time
    /// — sorting the whole corpus this way would push the timeless majority into an
    /// arbitrary tail.
    static func sortByRevisit(_ rows: [HouseRowModel]) -> [HouseRowModel] {
        rows.sorted {
            switch ($0.nextRevisitAt, $1.nextRevisitAt) {
            case let (lhs?, rhs?): lhs < rhs
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): $0.createdAt > $1.createdAt
            }
        }
    }

    /// Field-tested default: open work first, then newest.
    static func sort(_ rows: [HouseRowModel]) -> [HouseRowModel] {
        rows.sorted {
            if $0.openCount != $1.openCount { return $0.openCount > $1.openCount }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Nearest first, measured from where you are standing.
    ///
    /// Equirectangular metres rather than `CLLocation.distance(from:)`: at city
    /// scale the error is centimetres, and it avoids allocating an object per row
    /// every time the position updates.
    static func sortByDistance(
        _ rows: [HouseRowModel],
        from origin: CLLocationCoordinate2D
    ) -> [HouseRowModel] {
        let latitudeScale = 110_540.0
        let longitudeScale = 111_320.0 * cos(origin.latitude * .pi / 180)
        var measured = rows
        for index in measured.indices {
            let dLat = (measured[index].latitude - origin.latitude) * latitudeScale
            let dLon = (measured[index].longitude - origin.longitude) * longitudeScale
            measured[index].distance = (dLat * dLat + dLon * dLon).squareRoot()
        }
        return measured.sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
    }

    static func sections(from rows: [HouseRowModel]) -> [StreetSection] {
        var byStreet: [String: [HouseRowModel]] = [:]
        var order: [String] = []
        for row in rows {
            if byStreet[row.street] == nil { order.append(row.street) }
            byStreet[row.street, default: []].append(row)
        }
        return order
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { street in
                let rows = byStreet[street] ?? []
                var unitCount = 0
                var completed = 0
                var open = 0
                for row in rows {
                    unitCount += row.unitCount
                    completed += row.completedCount
                    open += row.openCount
                }
                return StreetSection(
                    id: "street:\(street)",
                    title: street,
                    rows: rows,
                    houseCount: rows.count,
                    unitCount: unitCount,
                    completedCount: completed,
                    openCount: open
                )
            }
    }

    static func counts(for rows: [HouseRowModel]) -> [ListFilter: Int] {
        var result: [ListFilter: Int] = [:]
        for filter in ListFilter.allCases {
            result[filter] = filter == .all ? rows.count : rows.filter(filter.matches).count
        }
        return result
    }

    /// Section ids that start shut: streets where nobody recorded anything yet.
    /// The list opens where work already happened. Derived from the street
    /// grouping itself, never from the distance/time views, whose single
    /// synthetic section must not decide for the streets.
    static func initiallyCollapsedSectionIDs(rows: [HouseRowModel]) -> Set<String> {
        Set(
            sections(from: sort(rows))
                .filter { $0.rows.allSatisfy { $0.completedCount == 0 } }
                .map(\.id)
        )
    }
}
