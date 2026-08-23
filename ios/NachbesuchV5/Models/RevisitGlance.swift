import Foundation

/// A booked return time, reduced to the one phrase worth reading while walking.
///
/// The row used to print "zurück um 18:30" and leave the arithmetic to you — which
/// is the wrong way round at 18:29. What matters on the street is *how far away* the
/// appointment is, so the phrasing switches with the distance: counted in minutes
/// while it is close, named as a clock time once it is far enough that the exact
/// minute stops mattering, and called overdue the moment it passes.
///
/// A value type rather than a formatted `String` so `HouseRow` can compare two
/// glances: a row whose chip would render identically must not re-render just
/// because the clock ticked.
nonisolated struct RevisitGlance: Equatable, Sendable {
    enum Urgency: Sendable, Equatable {
        /// The time has passed. Nothing else on the row outranks this.
        case overdue
        /// Within the hour — close enough to walk there now.
        case imminent
        /// Later today, or on a following day.
        case upcoming
    }

    let label: String
    let voiceOver: String
    let urgency: Urgency
    /// Doors beyond the first with their own booked time, shown as "+2".
    let extraDoors: Int

    var systemImage: String {
        switch urgency {
        case .overdue: "clock.badge.exclamationmark.fill"
        case .imminent: "alarm.fill"
        case .upcoming: "clock.fill"
        }
    }

    /// Same weekday abbreviation the rest of the app uses, fixed to de_AT so the
    /// chip does not switch languages with the device.
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    static func make(
        at date: Date?,
        laterDoors: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> RevisitGlance? {
        guard let date else { return nil }
        let extra = max(0, laterDoors - 1)
        let clock = RevisitPlanner.clockFormatter.string(from: date)
        // Rounded, not truncated: at 59 s to go, "in 0 Min" is a worse answer than
        // "in 1 Min", and the same rounding is what makes the chip flip to overdue
        // within half a minute of the booked time.
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())

        if minutes <= 0 {
            let late = -minutes
            return RevisitGlance(
                label: late < 60 ? "\(late) Min überfällig" : "überfällig",
                voiceOver: late < 60
                    ? "\(late) Minuten überfällig, war um \(clock) fällig"
                    : "überfällig seit \(clock)",
                urgency: .overdue,
                extraDoors: extra
            )
        }
        if minutes < 60 {
            return RevisitGlance(
                label: "in \(minutes) Min",
                voiceOver: "in \(minutes) Minuten zurück, um \(clock)",
                urgency: .imminent,
                extraDoors: extra
            )
        }
        // `isDateInToday` / `isDateInTomorrow` would ask the *system* what day it
        // is and ignore `now` entirely — the caller's clock has to be the reference,
        // or the chip and the injected time disagree the moment they differ.
        if calendar.isDate(date, inSameDayAs: now) {
            return RevisitGlance(
                label: "um \(clock)",
                voiceOver: "zurück um \(clock)",
                urgency: .upcoming,
                extraDoors: extra
            )
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        if let tomorrow, calendar.isDate(date, inSameDayAs: tomorrow) {
            return RevisitGlance(
                label: "morgen \(clock)",
                voiceOver: "morgen um \(clock) zurück",
                urgency: .upcoming,
                extraDoors: extra
            )
        }
        let weekday = weekdayFormatter.string(from: date)
        return RevisitGlance(
            label: "\(weekday) \(clock)",
            voiceOver: "zurück am \(weekday) um \(clock)",
            urgency: .upcoming,
            extraDoors: extra
        )
    }
}
