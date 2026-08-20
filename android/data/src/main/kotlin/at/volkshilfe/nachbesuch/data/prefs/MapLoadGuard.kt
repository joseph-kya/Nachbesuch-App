package at.volkshilfe.nachbesuch.data.prefs

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.time.Instant
import java.time.ZoneOffset

private val Context.mapSafetyPreferences by preferencesDataStore("map-safety")

/**
 * Persistent circuit breaker for accidental MapView recreation loops.
 *
 * This is deliberately generous for normal use but finite: a broken navigation or
 * lifecycle loop cannot create Google map hosts forever. It is not a substitute for
 * restricting the API key in Google Cloud because client-side limits can be bypassed
 * by someone who extracts a key from an APK.
 */
class MapLoadGuard(private val context: Context) {
    suspend fun acquire(nowMillis: Long = System.currentTimeMillis()): MapLoadPermit {
        val today = utcEpochDay(nowMillis)
        var permit: MapLoadPermit = MapLoadPermit.Allowed(1, MAX_MAP_HOSTS_PER_UTC_DAY)
        context.mapSafetyPreferences.edit { values ->
            val storedDay = values[Keys.epochDay]
            val previous = if (storedDay == today) values[Keys.loads] ?: 0 else 0
            if (previous >= MAX_MAP_HOSTS_PER_UTC_DAY) {
                permit = MapLoadPermit.Blocked(previous, MAX_MAP_HOSTS_PER_UTC_DAY)
            } else {
                val next = previous + 1
                values[Keys.epochDay] = today
                values[Keys.loads] = next
                permit = MapLoadPermit.Allowed(next, MAX_MAP_HOSTS_PER_UTC_DAY)
            }
        }
        return permit
    }

    private fun utcEpochDay(nowMillis: Long): Long = Instant.ofEpochMilli(nowMillis)
        .atZone(ZoneOffset.UTC)
        .toLocalDate()
        .toEpochDay()

    private object Keys {
        val epochDay = longPreferencesKey("utcEpochDay")
        val loads = intPreferencesKey("mapHostCreations")
    }

    companion object {
        // A fundraiser can reopen the map repeatedly without ever approaching this.
        // A runaway lifecycle loop stops after a bounded number of SDK map hosts.
        const val MAX_MAP_HOSTS_PER_UTC_DAY = 100
    }
}

sealed interface MapLoadPermit {
    val used: Int
    val limit: Int

    data class Allowed(override val used: Int, override val limit: Int) : MapLoadPermit
    data class Blocked(override val used: Int, override val limit: Int) : MapLoadPermit
}
