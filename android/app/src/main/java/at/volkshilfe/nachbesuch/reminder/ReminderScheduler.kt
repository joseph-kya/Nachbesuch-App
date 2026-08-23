package at.volkshilfe.nachbesuch.reminder

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/**
 * Every local notification the app schedules, in one place.
 *
 * Two independent jobs share this file because they share one permission, one
 * delivery path and one failure mode:
 *
 *  * **Nachbesuch-Erinnerungen** — a door marked "Später" books a return time and
 *    the reminder fires once at that time.
 *  * **Listen-Erinnerungen** — the standing 14:00 / 16:00 / 18:00 prompt to send
 *    the Nachbesuchsliste to the Teamleiter, Monday to Friday only.
 *
 * The iOS twin is `ReminderService`. It gets `UNUserNotificationCenter`, which owns
 * the schedule for it; here the schedule is ours to keep, so alarm request codes
 * are *derived* from the door they belong to. Re-recording a door therefore
 * replaces its pending alarm instead of stacking a second one on top, and a stale
 * one can be cancelled without a stored table of ids.
 */
class ReminderScheduler(private val context: Context) {

    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)

    companion object {
        const val ACTION_REVISIT = "at.volkshilfe.nachbesuch.action.REVISIT"
        const val ACTION_DAILY_LIST = "at.volkshilfe.nachbesuch.action.DAILY_LIST"

        const val EXTRA_HOUSE_ID = "houseID"
        const val EXTRA_DOOR_ID = "doorID"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_HOUR = "hour"

        const val CHANNEL_REVISIT = "nachbesuch.revisit"
        const val CHANNEL_DAILY = "nachbesuch.daily"

        /** The times the standing list reminder fires. */
        val DAILY_LIST_HOURS = listOf(14, 16, 18)

        /**
         * The days it fires on. Nobody sends the Nachbesuchsliste to the Teamleiter
         * at the weekend, so a Saturday notification is only something to swipe
         * away.
         */
        val DAILY_LIST_DAYS = setOf(
            DayOfWeek.MONDAY,
            DayOfWeek.TUESDAY,
            DayOfWeek.WEDNESDAY,
            DayOfWeek.THURSDAY,
            DayOfWeek.FRIDAY
        )

        const val DAILY_LIST_TITLE = "Nachbesuchsliste"
        const val DAILY_LIST_BODY = "Nachbesuchsliste an Teamleiter senden!"

        /**
         * Stable request code for one door's alarm.
         *
         * Derived, never random: this is what makes "replace" and "cancel" work
         * without persisting an id table of our own. The `and 0x7FFFFFFF` keeps it
         * non-negative and out of the daily reminders' small hour-based codes.
         */
        fun revisitRequestCode(houseID: String, doorID: String, day: Int): Int =
            ("$houseID|$doorID|$day".hashCode() and 0x7FFFFFFF) or 0x100

        fun dailyRequestCode(hour: Int): Int = hour
    }

    /**
     * Creates both channels.
     *
     * Cheap and idempotent, so it runs on every app start rather than being guarded
     * by a flag that could go stale after the user clears app data.
     */
    fun ensureChannels() {
        notifications.createNotificationChannel(
            NotificationChannel(
                CHANNEL_REVISIT,
                "Nachbesuche",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Erinnert an ein Haus, das du auf „Später“ gesetzt hast."
            }
        )
        notifications.createNotificationChannel(
            NotificationChannel(
                CHANNEL_DAILY,
                "Liste an Teamleiter",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Erinnert montags bis freitags um 14:00, 16:00 und 18:00 daran, die Liste zu senden."
            }
        )
    }

    // MARK: Revisit reminders

    /**
     * Books (or re-books) the reminder for one postponed door.
     *
     * A time in the past is treated as a cancellation — an alarm set in the past
     * fires immediately, which would mean a notification for a visit the user just
     * scheduled.
     */
    fun scheduleRevisit(
        houseID: String,
        doorID: String,
        day: Int,
        address: String,
        doorLabel: String,
        isApartmentBuilding: Boolean,
        atMillis: Long
    ) {
        if (atMillis <= System.currentTimeMillis()) {
            cancelRevisit(houseID, doorID, day)
            return
        }
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            action = ACTION_REVISIT
            putExtra(EXTRA_HOUSE_ID, houseID)
            putExtra(EXTRA_DOOR_ID, doorID)
            putExtra(EXTRA_TITLE, "Nachbesuch fällig")
            putExtra(EXTRA_BODY, if (isApartmentBuilding) "$address — $doorLabel" else address)
        }
        setAlarm(revisitRequestCode(houseID, doorID, day), intent, atMillis)
    }

    fun cancelRevisit(houseID: String, doorID: String, day: Int) {
        cancelAlarm(revisitRequestCode(houseID, doorID, day), ACTION_REVISIT)
    }

    /**
     * Re-derives every reminder of one house from its stored doors.
     *
     * Simpler and safer than reasoning about which doors changed — used after an
     * undo, where the write could have gone in either direction.
     */
    fun syncRevisits(house: House, day: Int) {
        val scope = if (day == 2) DayScope.DAY_2 else DayScope.DAY_1
        for (door in house.units) {
            val bookedAt = door.revisitTime(scope)
            if (door.result(scope) == VisitOutcome.LATER && bookedAt != null) {
                scheduleRevisit(
                    house.id, door.id, day, house.address, door.label,
                    house.isApartmentBuilding, bookedAt
                )
            } else {
                cancelRevisit(house.id, door.id, day)
            }
        }
    }

    /**
     * Drops every reminder belonging to a house — used when it is deleted, so a
     * notification can never point at an address that no longer exists.
     */
    fun cancelAllRevisits(house: House) {
        for (door in house.units) {
            cancelRevisit(house.id, door.id, 1)
            cancelRevisit(house.id, door.id, 2)
        }
    }

    // MARK: Daily list reminder

    /**
     * Applies the standing 14:00 / 16:00 / 18:00 reminder, Monday to Friday.
     *
     * Idempotent — it cancels the three alarms first, so calling it on every launch
     * cannot accumulate duplicates. Each alarm is a one-shot that the receiver
     * re-arms for the next day; a repeating alarm would drift and could not be
     * re-pointed at a changed hour list without a reinstall.
     */
    fun applyDailyListReminders(enabled: Boolean) {
        for (hour in DAILY_LIST_HOURS) {
            cancelAlarm(dailyRequestCode(hour), ACTION_DAILY_LIST)
        }
        if (!enabled) return
        for (hour in DAILY_LIST_HOURS) {
            scheduleDailyList(hour)
        }
    }

    /** Arms one daily reminder for its next occurrence. */
    fun scheduleDailyList(hour: Int, now: Long = System.currentTimeMillis()) {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            action = ACTION_DAILY_LIST
            putExtra(EXTRA_HOUR, hour)
            putExtra(EXTRA_TITLE, DAILY_LIST_TITLE)
            putExtra(EXTRA_BODY, DAILY_LIST_BODY)
        }
        setAlarm(dailyRequestCode(hour), intent, nextOccurrence(hour, now))
    }

    /**
     * The next weekday slot: today while it is still ahead, otherwise the next
     * Monday-to-Friday day at the same hour.
     *
     * The weekend is skipped here rather than in the receiver, so the alarm simply
     * never exists on a Saturday — a receiver that had to decide whether to post
     * would still wake the device twice a weekend for nothing.
     */
    fun nextOccurrence(hour: Int, now: Long, zone: ZoneId = ZoneId.systemDefault()): Long {
        val today = Instant.ofEpochMilli(now).atZone(zone)
            .with(LocalTime.of(hour, 0)).withSecond(0).withNano(0)
        var target = if (today.toInstant().toEpochMilli() > now) today else today.plusDays(1)
        while (target.dayOfWeek !in DAILY_LIST_DAYS) {
            target = target.plusDays(1)
        }
        return target.toInstant().toEpochMilli()
    }

    // MARK: Alarm plumbing

    private fun setAlarm(requestCode: Int, intent: Intent, atMillis: Long) {
        val pending = PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // Exact alarms need a user-grantable permission from Android 12 on. A
        // reminder that lands a few minutes late is far better than one that never
        // arrives, so an ungranted permission downgrades to an inexact window
        // instead of dropping the reminder.
        val canBeExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()
        if (canBeExact) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
        } else {
            alarms.setWindow(AlarmManager.RTC_WAKEUP, atMillis, 5 * 60_000L, pending)
        }
    }

    private fun cancelAlarm(requestCode: Int, action: String) {
        val intent = Intent(context, ReminderReceiver::class.java).apply { this.action = action }
        // NO_CREATE: if nothing is pending there is nothing to cancel, and creating
        // one just to cancel it would leak an alarm on every status change.
        val pending = PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        ) ?: return
        alarms.cancel(pending)
        pending.cancel()
        notifications.cancel(requestCode)
    }
}
