package at.volkshilfe.nachbesuch.data.prefs

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.settingsPreferences by preferencesDataStore("app-settings")

/**
 * User-facing toggles that must survive relaunches, matching the iOS
 * @AppStorage-backed keys: map style, POI preset and route overlay visibility.
 */
class AppSettingsStore(private val context: Context) {
    data class Values(
        val satellite: Boolean,
        val poiEssential: Boolean,
        val poiAll: Boolean,
        val routeVisible: Boolean,
        val exportVisitedOnly: Boolean,
        val exportIncludeNotes: Boolean,
        /** Raw `AppAppearance.storageValue`; the ui module owns the enum. */
        val appearance: String,
        /** Raw `AppAccent.storageValue`. */
        val accent: String,
        /**
         * The territory the user was last working in.
         *
         * Persisted for the same reason as the map camera: "where I left off" is
         * part of the app's state. Holding it only in the ViewModel meant every
         * relaunch silently reset it to whichever territory sorted first, which is
         * the bug the iOS `selectedGebietID` @AppStorage key exists to prevent.
         */
        val selectedGebietID: String?,
        /**
         * The standing "send the list" reminder. Default on — the prompt is the
         * reason the feature exists; a reminder nobody switched on reminds nobody.
         */
        val dailyListReminders: Boolean
    )

    private object Keys {
        val satellite = booleanPreferencesKey("map.usesSatellite")
        val poiEssential = booleanPreferencesKey("map.poi.essential")
        val poiAll = booleanPreferencesKey("map.poi.all")
        val routeVisible = booleanPreferencesKey("route.overlayVisible")
        val exportVisitedOnly = booleanPreferencesKey("export.visitedOnly")
        val exportIncludeNotes = booleanPreferencesKey("export.includeNotes")
        val appearance = stringPreferencesKey("appearance.mode")
        val accent = stringPreferencesKey("appearance.accent")
        val selectedGebietID = stringPreferencesKey("selectedGebietID")
        val dailyListReminders = booleanPreferencesKey("reminders.dailyList")
    }

    suspend fun restore(): Values {
        val values = context.settingsPreferences.data.first()
        return Values(
            satellite = values[Keys.satellite] ?: false,
            poiEssential = values[Keys.poiEssential] ?: true,
            poiAll = values[Keys.poiAll] ?: false,
            routeVisible = values[Keys.routeVisible] ?: true,
            exportVisitedOnly = values[Keys.exportVisitedOnly] ?: true,
            // iOS defaults includeNotes to true; Android historically forced it off.
            exportIncludeNotes = values[Keys.exportIncludeNotes] ?: true,
            appearance = values[Keys.appearance] ?: "system",
            accent = values[Keys.accent] ?: "volkshilfe",
            // Empty string is how a cleared selection is stored; it is not a valid id.
            selectedGebietID = values[Keys.selectedGebietID]?.takeIf { it.isNotBlank() },
            dailyListReminders = values[Keys.dailyListReminders] ?: true
        )
    }

    suspend fun record(values: Values) {
        context.settingsPreferences.edit { current ->
            current[Keys.satellite] = values.satellite
            current[Keys.poiEssential] = values.poiEssential
            current[Keys.poiAll] = values.poiAll
            current[Keys.routeVisible] = values.routeVisible
            current[Keys.exportVisitedOnly] = values.exportVisitedOnly
            current[Keys.exportIncludeNotes] = values.exportIncludeNotes
            current[Keys.appearance] = values.appearance
            current[Keys.accent] = values.accent
            current[Keys.selectedGebietID] = values.selectedGebietID.orEmpty()
            current[Keys.dailyListReminders] = values.dailyListReminders
        }
    }

    /** Writes only the reminder toggle, for the same reason as [recordAppearance]. */
    suspend fun recordDailyListReminders(enabled: Boolean) {
        context.settingsPreferences.edit { current ->
            current[Keys.dailyListReminders] = enabled
        }
    }

    /**
     * Writes the appearance pair on its own.
     *
     * The settings sheet must not have to round-trip every unrelated map and export
     * toggle through [record] just to change a colour — doing so would let a stale
     * in-memory copy clobber a map setting changed on another screen.
     */
    suspend fun recordAppearance(appearance: String, accent: String) {
        context.settingsPreferences.edit { current ->
            current[Keys.appearance] = appearance
            current[Keys.accent] = accent
        }
    }

    /** Writes only the active territory, for the same reason as [recordAppearance]. */
    suspend fun recordSelectedGebiet(id: String?) {
        context.settingsPreferences.edit { current ->
            current[Keys.selectedGebietID] = id.orEmpty()
        }
    }

    /** Observes the appearance pair so theme changes apply without a relaunch. */
    fun observeAppearance(): Flow<Pair<String, String>> =
        context.settingsPreferences.data.map { values ->
            (values[Keys.appearance] ?: "system") to (values[Keys.accent] ?: "volkshilfe")
        }
}
