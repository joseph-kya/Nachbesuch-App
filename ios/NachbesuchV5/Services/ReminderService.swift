import Foundation
import UserNotifications

/// Every local notification the app schedules, in one place.
///
/// Two independent jobs share this file because they share one authorization and
/// one failure mode:
///
/// * **Nachbesuch-Erinnerungen** — a door marked "Später" books a return time, and
///   the reminder fires once at that time.
/// * **Listen-Erinnerungen** — the standing 14:00 / 16:00 / 18:00 prompt to send the
///   Nachbesuchsliste to the Teamleiter, Monday to Friday only.
///
/// Identifiers are derived, never random, so re-recording a door replaces its
/// pending reminder instead of stacking a second one on top.
/// The `AppStorage` keys the reminder feature owns.
nonisolated enum ReminderSettings {
    /// Whether the standing 14/16/18 list reminder is scheduled. Default on — the
    /// prompt is the reason the feature was asked for.
    nonisolated static let dailyListKey = "reminders.dailyList"
}

nonisolated enum ReminderService {
    // MARK: Identifiers

    private static let revisitPrefix = "revisit"
    private static let dailyPrefix = "dailyList"

    /// The times the standing list reminder fires.
    nonisolated static let dailyListHours = [14, 16, 18]

    /// The days it fires on, in `Calendar` numbering (1 = Sunday). Monday to
    /// Friday: nobody sends the Nachbesuchsliste to the Teamleiter at the weekend,
    /// and a Saturday banner is just a notification to swipe away.
    nonisolated static let dailyListWeekdays = [2, 3, 4, 5, 6]

    nonisolated static let dailyListTitle = "Nachbesuchsliste"
    nonisolated static let dailyListBody = "Nachbesuchsliste an Teamleiter senden!"

    nonisolated static func revisitIdentifier(house: UUID, door: UUID, day: Int) -> String {
        "\(revisitPrefix).\(house.uuidString).\(door.uuidString).\(day)"
    }

    private static func dailyIdentifier(hour: Int, weekday: Int) -> String {
        "\(dailyPrefix).\(hour).\(weekday)"
    }

    /// Identifiers of every list reminder this app has ever scheduled, including
    /// the pre-weekday `dailyList.14` form. A build that upgrades over the old one
    /// would otherwise keep firing the daily requests on Saturday forever — nothing
    /// else ever removes them.
    private static var allDailyIdentifiers: [String] {
        dailyListHours.map { "\(dailyPrefix).\($0)" }
            + dailyListHours.flatMap { hour in
                dailyListWeekdays.map { dailyIdentifier(hour: hour, weekday: $0) }
            }
    }

    // MARK: Authorization

    /// Asks for permission if it has never been asked, and reports whether
    /// notifications may be posted at all.
    ///
    /// Returns `false` rather than throwing on a denied or restricted setting: the
    /// caller's job is to tell the user their reminder will not appear, not to
    /// handle an error type.
    @discardableResult
    nonisolated static func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    // MARK: Revisit reminders

    /// Books (or re-books) the reminder for one postponed door.
    ///
    /// A time in the past is treated as a cancellation — `UNCalendarNotificationTrigger`
    /// would otherwise either fire immediately or roll silently into tomorrow.
    nonisolated static func scheduleRevisit(
        house: UUID,
        door: UUID,
        day: Int,
        address: String,
        doorLabel: String,
        isApartmentBuilding: Bool,
        at date: Date
    ) async {
        let identifier = revisitIdentifier(house: house, door: door, day: day)
        guard date > .now else {
            await cancel(identifiers: [identifier])
            return
        }
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Nachbesuch fällig"
        content.body = isApartmentBuilding ? "\(address) — \(doorLabel)" : address
        content.sound = .default
        content.userInfo = ["houseID": house.uuidString, "doorID": door.uuidString]
        content.interruptionLevel = .timeSensitive

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated static func cancelRevisit(house: UUID, door: UUID, day: Int) async {
        await cancel(identifiers: [revisitIdentifier(house: house, door: door, day: day)])
    }

    /// Drops every reminder belonging to a house — used when the house is deleted,
    /// so a notification can never point at an address that no longer exists.
    nonisolated static func cancelAllRevisits(house: UUID) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let prefix = "\(revisitPrefix).\(house.uuidString)."
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !identifiers.isEmpty else { return }
        await cancel(identifiers: identifiers)
    }

    // MARK: Daily list reminder

    /// Applies the standing 14:00 / 16:00 / 18:00 reminder, Monday to Friday.
    ///
    /// One repeating request per hour *and weekday* — fifteen in total. A single
    /// request with only `hour` set repeats every day, and `UNCalendarNotificationTrigger`
    /// has no way to exclude the weekend, so the weekday has to be part of the
    /// match components.
    ///
    /// Idempotent — it always removes every known request first, so calling it on
    /// every launch cannot accumulate duplicates.
    nonisolated static func applyDailyListReminders(enabled: Bool) async {
        await cancel(identifiers: allDailyIdentifiers)
        guard enabled, await ensureAuthorized() else { return }

        let center = UNUserNotificationCenter.current()
        for hour in dailyListHours {
            for weekday in dailyListWeekdays {
                let content = UNMutableNotificationContent()
                content.title = dailyListTitle
                content.body = dailyListBody
                content.sound = .default

                var components = DateComponents()
                components.weekday = weekday
                components.hour = hour
                components.minute = 0
                let request = UNNotificationRequest(
                    identifier: dailyIdentifier(hour: hour, weekday: weekday),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                )
                try? await center.add(request)
            }
        }
    }

    // MARK: Shared

    private static func cancel(identifiers: [String]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Shows reminders while the app is in the foreground.
///
/// Without a delegate, iOS suppresses banners for an app that is already open —
/// which is exactly the situation this feature is for: the canvasser is standing on
/// the street with the map on screen when the 18:00 revisit comes due.
final class ReminderPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderPresenter()

    /// Called once, before the first scene connects.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
