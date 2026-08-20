import Foundation

/// The single implementation of "count what happened at these doors".
///
/// This logic previously existed five times over — in `HouseSummary`, the map's
/// snapshot builder, the archive index, the balance engine and the PDF exporter —
/// each with its own copy of the day-scope rule. They drifted, which is how the
/// map, the list and the archive ended up reporting different numbers for the same
/// house. Everything now funnels through here.
nonisolated struct OutcomeTally: Sendable, Hashable {
    /// Doors that exist.
    var unitCount = 0
    /// Doors with a recorded result in this scope.
    var completed = 0
    /// Doors still needing a visit in this scope.
    var open = 0
    var notHome = 0
    var earlyNo = 0
    var lateNo = 0
    var joined = 0

    static let empty = OutcomeTally()

    var isComplete: Bool { unitCount > 0 && completed == unitCount }

    var completionFraction: Double {
        unitCount > 0 ? Double(completed) / Double(unitCount) : 0
    }

    mutating func ingest(_ door: DoorResult, scope: DayScope) {
        unitCount += 1
        if door.isOpen(in: scope) { open += 1 }
        guard let outcome = door.displayOutcome(in: scope) else { return }
        completed += 1
        switch outcome {
        case .notHome: notHome += 1
        case .earlyNo: earlyNo += 1
        case .lateNo: lateNo += 1
        case .joined: joined += 1
        }
    }

    mutating func merge(_ other: OutcomeTally) {
        unitCount += other.unitCount
        completed += other.completed
        open += other.open
        notHome += other.notHome
        earlyNo += other.earlyNo
        lateNo += other.lateNo
        joined += other.joined
    }

    static func tally(_ doors: [DoorResult], scope: DayScope) -> OutcomeTally {
        var result = OutcomeTally()
        for door in doors { result.ingest(door, scope: scope) }
        return result
    }

    /// The single outcome that best represents a whole house on a map pin.
    /// Open work wins over everything so a half-finished building never looks done.
    static func markerOutcome(for doors: [DoorResult], scope: DayScope) -> VisitOutcome? {
        var last: VisitOutcome?
        var hasFollowUp = false
        var hasJoined = false
        for door in doors {
            guard let outcome = door.displayOutcome(in: scope) else { continue }
            last = outcome
            if outcome == .notHome { hasFollowUp = true }
            if outcome == .joined { hasJoined = true }
        }
        if hasFollowUp { return .notHome }
        if hasJoined { return .joined }
        return last
    }
}

/// A decoded, counted view of one house. Purely a value — building one costs a JSON
/// decode, so callers memoize it rather than the model caching it internally.
nonisolated struct HouseSummary: Sendable {
    let units: [DoorResult]
    let scope: DayScope
    let tally: OutcomeTally
    let markerOutcome: VisitOutcome?

    nonisolated init(units: [DoorResult], scope: DayScope = .combined) {
        self.units = units
        self.scope = scope
        tally = OutcomeTally.tally(units, scope: scope)
        markerOutcome = OutcomeTally.markerOutcome(for: units, scope: scope)
    }

    nonisolated var completedCount: Int { tally.completed }
    nonisolated var followUpCount: Int { tally.notHome }
    nonisolated var joinedCount: Int { tally.joined }
    nonisolated var openCount: Int { tally.open }
    nonisolated var unansweredCount: Int { tally.unitCount - tally.completed }

    /// What the pin shows. Scope-aware — reading `units.first?.outcome` directly is
    /// what made the list and the map disagree in Tag-2 mode.
    nonisolated var markerText: String {
        units.count == 1
            ? (markerOutcome?.emoji ?? "•")
            : "\(tally.completed)/\(units.count)"
    }
}
