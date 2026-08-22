import Foundation

/// One household / door within a `House`.
///
/// A two-day territory records two independent results per door: what happened on
/// the first pass and what happened on the revisit. Keeping them separate is the
/// whole point of the feature, so the accessors below are deliberately explicit
/// about which question they answer — the previous single `outcome(for:)` returned
/// the same value for "Tag 2" and "Gesamt", which silently made every day-2
/// statistic a copy of the total.
nonisolated struct DoorResult: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var label: String
    /// The day-1 result.
    var outcome: VisitOutcome?
    var updatedAt: Date?
    /// When to come back, for a `.later` result on day 1. `nil` for every other
    /// outcome.
    ///
    /// Added after the storage format froze. It is a *new optional key*, which both
    /// `JSONDecoder` and Android's `ignoreUnknownKeys` reader treat as absent →
    /// `nil`, so blobs written by earlier builds still decode and blobs written by
    /// this build still open in them.
    var revisitAt: Date?
    /// The day-2 result. `nil` means "not revisited yet", which is meaningful.
    var day2Outcome: VisitOutcome?
    var day2UpdatedAt: Date?
    /// The day-2 twin of `revisitAt`.
    var day2RevisitAt: Date?

    nonisolated init(
        id: UUID = UUID(),
        label: String,
        outcome: VisitOutcome? = nil,
        updatedAt: Date? = nil,
        revisitAt: Date? = nil,
        day2Outcome: VisitOutcome? = nil,
        day2UpdatedAt: Date? = nil,
        day2RevisitAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.outcome = outcome
        self.updatedAt = updatedAt
        self.revisitAt = revisitAt
        self.day2Outcome = day2Outcome
        self.day2UpdatedAt = day2UpdatedAt
        self.day2RevisitAt = day2RevisitAt
    }

    // MARK: Strict accessors — for statistics

    /// What was actually recorded on the given campaign day. No fallback: a door
    /// answered only on day 1 has **no** day-2 result, and counting it as one is
    /// what made the Tag-1/Tag-2 comparison meaningless.
    nonisolated func result(on day: Int) -> VisitOutcome? {
        day == 2 ? day2Outcome : outcome
    }

    /// The agreed return time recorded on the given campaign day.
    nonisolated func revisitTime(on day: Int) -> Date? {
        day == 2 ? day2RevisitAt : revisitAt
    }

    /// The door's final state across the whole territory.
    nonisolated var finalOutcome: VisitOutcome? {
        day2Outcome ?? outcome
    }

    /// The return time that goes with `finalOutcome`, so a pin or row never shows a
    /// day-1 time next to a day-2 status.
    nonisolated var finalRevisitAt: Date? {
        day2Outcome == nil ? revisitAt : day2RevisitAt
    }

    /// True when day 1 left this door open and the revisit hasn't happened yet —
    /// i.e. exactly the work a second day exists to do.
    nonisolated var isPendingRevisit: Bool {
        outcome?.isOpenWork == true && day2Outcome == nil
    }

    /// What this door contributes to a report for `scope`.
    ///
    /// Strict, and deliberately different from `displayOutcome(in:)`: a report headed
    /// "Tag 2" must not list a door that was settled on day 1 and never revisited,
    /// however sensible showing that value is on a pin.
    nonisolated func recordedOutcome(in scope: DayScope) -> VisitOutcome? {
        switch scope {
        case .day1: return outcome
        case .day2: return day2Outcome
        case .combined: return finalOutcome
        }
    }

    // MARK: Display accessor — for pins and rows

    /// What the user should see for this door in the given scope.
    ///
    /// In `.day2` a door that is still awaiting its revisit reads as *unanswered*
    /// rather than showing its day-1 "niemand da" — otherwise the doors you came
    /// back for are the ones the screen marks as finished.
    nonisolated func displayOutcome(in scope: DayScope) -> VisitOutcome? {
        switch scope {
        case .day1:
            return outcome
        case .day2:
            if let day2Outcome { return day2Outcome }
            return outcome?.isOpenWork == true ? nil : outcome
        case .combined:
            return finalOutcome
        }
    }

    /// The return time belonging to `displayOutcome(in:)`.
    nonisolated func displayRevisitAt(in scope: DayScope) -> Date? {
        switch scope {
        case .day1: return outcome == .later ? revisitAt : nil
        case .day2: return day2Outcome == .later ? day2RevisitAt : nil
        case .combined: return finalOutcome == .later ? finalRevisitAt : nil
        }
    }

    /// Whether this door counts as "still to do" in the given scope.
    nonisolated func isOpen(in scope: DayScope) -> Bool {
        switch scope {
        case .day1:
            return outcome == nil || outcome?.isOpenWork == true
        case .day2:
            return isPendingRevisit || (outcome == nil && day2Outcome == nil)
        case .combined:
            return finalOutcome == nil || finalOutcome?.isOpenWork == true
        }
    }

    /// When the result shown for `scope` was recorded.
    nonisolated func timestamp(in scope: DayScope) -> Date? {
        switch scope {
        case .day1: return updatedAt
        case .day2: return day2UpdatedAt ?? updatedAt
        case .combined: return day2UpdatedAt ?? updatedAt
        }
    }
}
