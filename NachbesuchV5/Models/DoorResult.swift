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
    /// The day-2 result. `nil` means "not revisited yet", which is meaningful.
    var day2Outcome: VisitOutcome?
    var day2UpdatedAt: Date?

    nonisolated init(
        id: UUID = UUID(),
        label: String,
        outcome: VisitOutcome? = nil,
        updatedAt: Date? = nil,
        day2Outcome: VisitOutcome? = nil,
        day2UpdatedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.outcome = outcome
        self.updatedAt = updatedAt
        self.day2Outcome = day2Outcome
        self.day2UpdatedAt = day2UpdatedAt
    }

    // MARK: Strict accessors — for statistics

    /// What was actually recorded on the given campaign day. No fallback: a door
    /// answered only on day 1 has **no** day-2 result, and counting it as one is
    /// what made the Tag-1/Tag-2 comparison meaningless.
    nonisolated func result(on day: Int) -> VisitOutcome? {
        day == 2 ? day2Outcome : outcome
    }

    /// The door's final state across the whole territory.
    nonisolated var finalOutcome: VisitOutcome? {
        day2Outcome ?? outcome
    }

    /// True when day 1 left this door open and the revisit hasn't happened yet —
    /// i.e. exactly the work a second day exists to do.
    nonisolated var isPendingRevisit: Bool {
        outcome == .notHome && day2Outcome == nil
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
            return outcome == .notHome ? nil : outcome
        case .combined:
            return finalOutcome
        }
    }

    /// Whether this door counts as "still to do" in the given scope.
    nonisolated func isOpen(in scope: DayScope) -> Bool {
        switch scope {
        case .day1:
            return outcome == nil || outcome == .notHome
        case .day2:
            return isPendingRevisit || (outcome == nil && day2Outcome == nil)
        case .combined:
            return finalOutcome == nil || finalOutcome == .notHome
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
