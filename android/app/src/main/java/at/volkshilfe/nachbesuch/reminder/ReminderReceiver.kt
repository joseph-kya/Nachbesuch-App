package at.volkshilfe.nachbesuch.reminder

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import at.volkshilfe.nachbesuch.MainActivity
import at.volkshilfe.nachbesuch.R

/**
 * Turns a fired alarm into a notification.
 *
 * A daily reminder also re-arms itself for tomorrow here. That is deliberate: a
 * repeating alarm cannot be re-pointed at a changed hour list, and it drifts under
 * doze. One-shot plus re-arm keeps the schedule exactly where
 * [ReminderScheduler.applyDailyListReminders] put it.
 */
class ReminderReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra(ReminderScheduler.EXTRA_TITLE) ?: return
        val body = intent.getStringExtra(ReminderScheduler.EXTRA_BODY) ?: return
        val scheduler = ReminderScheduler(context)
        scheduler.ensureChannels()

        when (intent.action) {
            ReminderScheduler.ACTION_REVISIT -> {
                val houseID = intent.getStringExtra(ReminderScheduler.EXTRA_HOUSE_ID).orEmpty()
                val doorID = intent.getStringExtra(ReminderScheduler.EXTRA_DOOR_ID).orEmpty()
                post(
                    context,
                    id = ("$houseID|$doorID".hashCode() and 0x7FFFFFFF) or 0x100,
                    channel = ReminderScheduler.CHANNEL_REVISIT,
                    title = title,
                    body = body
                )
            }

            ReminderScheduler.ACTION_DAILY_LIST -> {
                val hour = intent.getIntExtra(ReminderScheduler.EXTRA_HOUR, -1)
                post(
                    context,
                    id = ReminderScheduler.dailyRequestCode(hour),
                    channel = ReminderScheduler.CHANNEL_DAILY,
                    title = title,
                    body = body
                )
                if (hour >= 0) scheduler.scheduleDailyList(hour)
            }
        }
    }

    private fun post(context: Context, id: Int, channel: String, title: String, body: String) {
        val open = PendingIntent.getActivity(
            context,
            id,
            Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_nachbesuch)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        // No permission check: from Android 13 an ungranted POST_NOTIFICATIONS makes
        // this a no-op rather than a crash, and there is nothing useful to do about
        // it from inside a fired alarm.
        context.getSystemService(NotificationManager::class.java).notify(id, notification)
    }
}
