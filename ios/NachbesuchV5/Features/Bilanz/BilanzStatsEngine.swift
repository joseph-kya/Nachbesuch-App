import Foundation

/// Territory-level statistics.
///
/// The day-1 / day-2 comparison is the point of the two-day feature, and it used to
/// be meaningless: both days were computed through an accessor that fell back to the
/// day-1 value, so `day2` was arithmetically identical to the combined total and the
/// two columns could never differ. Day 2 is now measured strictly — only what was
/// actually recorded on the revisit — against the doors that were genuinely eligible
/// for one.
nonisolated struct BilanzSnapshot: Sendable, Equatable {
    var houseCount = 0
    /// Everything recorded, both days combined.
    var overall = OutcomeTally.empty
    /// Recorded on the first pass.
    var day1 = OutcomeTally.empty
    /// Recorded on the revisit — never inherited from day 1.
    var day2 = OutcomeTally.empty
    /// Doors that day 1 left open and day 2 has not yet answered.
    var pendingRevisits = 0
    /// Doors eligible for a revisit at all: the denominator day 2 should be judged by.
    var revisitTargets = 0

    static let empty = BilanzSnapshot()

    var day2Progress: Double {
        revisitTargets > 0 ? Double(day2.completed) / Double(revisitTargets) : 0
    }

    func tally(for scope: DayScope) -> OutcomeTally {
        switch scope {
        case .combined: overall
        case .day1: day1
        case .day2: day2
        }
    }
}

nonisolated enum BilanzStatsEngine {
    /// Coordinate-free house input so the engine can run off the main actor.
    struct HouseSeed: Sendable {
        let unitsData: Data

        init(unitsData: Data) {
            self.unitsData = unitsData
        }
    }

    static func build(from seeds: [HouseSeed]) -> BilanzSnapshot {
        let decoder = AppCoders.unitsDecoder()
        var snapshot = BilanzSnapshot()
        snapshot.houseCount = seeds.count

        for seed in seeds {
            guard let doors = try? decoder.decode([DoorResult].self, from: seed.unitsData) else { continue }
            for door in doors {
                snapshot.overall.ingest(door, scope: .combined)

                // Day 1: strictly what the first pass recorded.
                snapshot.day1.unitCount += 1
                if let day1Outcome = door.result(on: 1) {
                    snapshot.day1.completed += 1
                    snapshot.day1.add(day1Outcome)
                } else {
                    snapshot.day1.open += 1
                }

                // Day 2 is only meaningful for doors that needed one.
                let isRevisitTarget = door.outcome == .notHome || door.outcome == nil
                if isRevisitTarget { snapshot.revisitTargets += 1 }
                snapshot.day2.unitCount += 1
                if let day2Outcome = door.result(on: 2) {
                    snapshot.day2.completed += 1
                    snapshot.day2.add(day2Outcome)
                } else {
                    if isRevisitTarget { snapshot.day2.open += 1 }
                    if door.isPendingRevisit { snapshot.pendingRevisits += 1 }
                }
            }
        }
        return snapshot
    }
}

nonisolated extension OutcomeTally {
    /// Records an outcome whose "completed" bookkeeping the caller already handled.
    mutating func add(_ outcome: VisitOutcome) {
        switch outcome {
        case .notHome: notHome += 1
        case .earlyNo: earlyNo += 1
        case .lateNo: lateNo += 1
        case .joined: joined += 1
        case .later: later += 1
        }
    }
}
