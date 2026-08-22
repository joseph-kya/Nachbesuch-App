import Foundation

/// One offered return time for a `.later` door.
nonisolated struct RevisitSuggestion: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        /// "in 30 Minuten" — measured from the moment of tapping.
        case relative(minutes: Int)
        /// A fixed time of day, e.g. 18:00.
        case clock(hour: Int, minute: Int)
    }

    let kind: Kind
    let date: Date

    nonisolated var id: String {
        switch kind {
        case let .relative(minutes): "rel-\(minutes)"
        case let .clock(hour, minute): "clock-\(hour)-\(minute)"
        }
    }

    nonisolated var title: String {
        switch kind {
        case let .relative(minutes):
            minutes % 60 == 0 ? "In \(minutes / 60) Std" : "In \(minutes) Min"
        case let .clock(hour, minute):
            String(format: "Um %02d:%02d", hour, minute)
        }
    }

    /// The resulting clock time, shown under a relative title so the user sees what
    /// they are actually booking.
    nonisolated var clockText: String {
        RevisitPlanner.clockFormatter.string(from: date)
    }
}

/// Builds the shortlist of return times offered when a door is marked "Später".
///
/// Pure and calendar-injectable so the boundary cases — late evening, a slot that
/// has just passed, a relative offset landing on a suggested clock slot — are unit
/// tested rather than discovered in the field. The Android build carries a literal
/// port of these rules in `RevisitPlanner.kt`; the two must stay in step.
nonisolated enum RevisitPlanner {
    /// Offsets from "now". Rounded up to the next five minutes so the booked time
    /// reads as a clock time a person would say out loud.
    nonisolated static let relativeOffsets = [30, 60, 120]

    /// The hours people are actually home. Only those still ahead are offered.
    nonisolated static let clockSlots = [(hour: 17, minute: 0), (hour: 18, minute: 0), (hour: 19, minute: 0)]

    /// Two clock slots at most, so the row never scrolls on a small phone.
    nonisolated static let maximumClockSlots = 2

    /// A suggestion is dropped when another one is already within this window —
    /// offering "In 1 Std" and "Um 18:00" for the same minute is noise.
    nonisolated static let duplicateWindow: TimeInterval = 10 * 60

    nonisolated static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    nonisolated static func suggestions(now: Date = .now, calendar: Calendar = .current) -> [RevisitSuggestion] {
        var result: [RevisitSuggestion] = []

        for minutes in relativeOffsets {
            let date = roundedUpToFiveMinutes(now.addingTimeInterval(TimeInterval(minutes * 60)), calendar: calendar)
            result.append(RevisitSuggestion(kind: .relative(minutes: minutes), date: date))
        }

        var clockCount = 0
        for slot in clockSlots where clockCount < maximumClockSlots {
            guard let date = calendar.date(
                bySettingHour: slot.hour, minute: slot.minute, second: 0, of: now
            ) else { continue }
            // A slot that has already passed today is not a suggestion; rolling it
            // to tomorrow would silently book a visit for the next day.
            guard date > now else { continue }
            guard !result.contains(where: { abs($0.date.timeIntervalSince(date)) < duplicateWindow }) else { continue }
            result.append(RevisitSuggestion(kind: .clock(hour: slot.hour, minute: slot.minute), date: date))
            clockCount += 1
        }

        return result.sorted { $0.date < $1.date }
    }

    /// The initial value of the free time picker: the first suggestion, or half an
    /// hour out when the day is too late for any of them.
    nonisolated static func defaultTime(now: Date = .now, calendar: Calendar = .current) -> Date {
        suggestions(now: now, calendar: calendar).first?.date
            ?? roundedUpToFiveMinutes(now.addingTimeInterval(30 * 60), calendar: calendar)
    }

    nonisolated static func roundedUpToFiveMinutes(_ date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let minute = components.minute else { return date }
        let remainder = minute % 5
        components.second = 0
        if remainder != 0 {
            components.minute = minute + (5 - remainder)
        }
        return calendar.date(from: components) ?? date
    }
}
