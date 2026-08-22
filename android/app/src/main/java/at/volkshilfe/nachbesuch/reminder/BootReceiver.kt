package at.volkshilfe.nachbesuch.reminder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import at.volkshilfe.nachbesuch.data.local.AppDatabase
import at.volkshilfe.nachbesuch.data.local.TerritoryRepository
import at.volkshilfe.nachbesuch.data.prefs.AppSettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Puts the schedule back after a reboot.
 *
 * Android drops every pending alarm on shutdown. The daily reminders are trivial to
 * re-arm, and the booked "Später" times are re-derived from the database rather
 * than from a list of our own — the doors *are* the schedule, so there is no second
 * copy to fall out of step.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        val app = context.applicationContext
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val scheduler = ReminderScheduler(app)
                scheduler.ensureChannels()
                scheduler.applyDailyListReminders(AppSettingsStore(app).restore().dailyListReminders)

                val houses = TerritoryRepository(AppDatabase.open(app)).observeAllHouses().first()
                for (house in houses) {
                    // Both days: which one a house is "on" depends on its territory
                    // calendar, and a booked time only exists where one was written.
                    scheduler.syncRevisits(house, day = 1)
                    scheduler.syncRevisits(house, day = 2)
                }
            } catch (_: Throwable) {
                // A reboot is not a moment to crash in. Losing the re-arm is
                // recoverable — the next app launch re-applies the whole schedule.
            } finally {
                pending.finish()
            }
        }
    }
}
