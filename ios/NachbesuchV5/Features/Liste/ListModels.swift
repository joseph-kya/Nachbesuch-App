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
    let markerOutcome: VisitOutcome?
    let unitCount: Int
    let completedCount: Int
    let followUpCount: Int
    let joinedCount: Int
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

    var subtitle: String {
        let base = isSingleDoor
            ? markerOutcome.displayTitleValue
            : "\(completedCount)/\(unitCount) Türen · \(openCount) offen"
        // A booked return time replaces the "last recorded" stamp: on a row that
        // says "Später", when you are due back is the only time that matters.
        if let nextRevisitAt {
            return "\(base) · zurück um \(RevisitPlanner.clockFormatter.string(from: nextRevisitAt))"
        }
        guard let recordedAt else { return base }
        return "\(base) · \(recordedAt.formatted(date: .omitted, time: .shortened))"
    }

    /// What VoiceOver reads instead of an emoji.
    var accessibilityValue: String {
        let base = isSingleDoor
            ? markerOutcome.displayTitleValue
            : "\(completedCount) von \(unitCount) Türen erledigt, \(openCount) offen"
        guard let nextRevisitAt else { return base }
        return "\(base), zurück um \(RevisitPlanner.clockFormatter.string(from: nextRevisitAt))"
    }
}

extension Optional where Wrapped == VisitOutcome {
    nonisolated var displayTitleValue: String { self?.title ?? "Noch kein Status" }
}

nonisolated enum ListFilter: String, CaseIterable, Identifiable, Sendable {
    case all, open, unanswered, joined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Alle"
        case .open: "Offen"
        case .unanswered: "Ohne Status"
        case .joined: "Dabei"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "list.bullet"
        case .open: "arrow.clockwise"
        case .unanswered: "questionmark.circle"
        case .joined: "heart.fill"
        }
    }

    var tint: String {
        switch self {
        case .all: "secondary"
        case .open: "red"
        case .unanswered: "orange"
        case .joined: "pink"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "Noch keine Häuser"
        case .open: "Keine offenen Nachbesuche"
        case .unanswered: "Alles eingetragen"
        case .joined: "Noch keine Beitritte"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Füge auf der Karte dein erstes Haus hinzu."
        case .open: "Für diesen Zeitraum ist nichts mehr offen."
        case .unanswered: "Jeder erfasste Haushalt hat bereits einen Status."
        case .joined: "Hier erscheinen Haushalte, die dabei sind."
        }
    }

    func matches(_ row: HouseRowModel) -> Bool {
        switch self {
        case .all: true
        case .open: row.openCount > 0
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

    var progress: Double {
        unitCount > 0 ? Double(completedCount) / Double(unitCount) : 0
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
                markerOutcome: OutcomeTally.markerOutcome(for: doors, scope: scope),
                unitCount: doors.count,
                completedCount: tally.completed,
                followUpCount: tally.notHome,
                joinedCount: tally.joined,
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
}
